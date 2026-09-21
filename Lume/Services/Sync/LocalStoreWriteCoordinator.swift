//
//  LocalStoreWriteCoordinator.swift
//  Lume
//
//  One gate in front of every write to the local store. Guide publication,
//  catalog publication, area repair, the local apply phase of cloud reconcile
//  and store maintenance all reach the same SwiftData container from different
//  actors; without a shared gate they interleave and a reader can observe half
//  of two snapshots at once.
//
//  This is a queue with an admission rule, not a framework. It grants leases;
//  it never touches the store itself. Callers keep owning their own work and
//  their own fence revalidation immediately before `save()`.
//
//  ┌─ Lease modes ──────────────────────────────────────────────────────────┐
//  │                                                                        │
//  │   .shared     staging inserts — additive rows no reader can see yet.   │
//  │               Several may hold at once, so a full-guide staging pass   │
//  │               does not block a catalog sync for minutes.               │
//  │                                                                        │
//  │   .exclusive  publication, prune, area repair, cloud local-apply,      │
//  │               runtime store maintenance. Held alone.                   │
//  │                                                                        │
//  │        shared ──┐                                                      │
//  │        shared ──┼──► overlap freely                                    │
//  │        shared ──┘                                                      │
//  │        exclusive ─► alone; waits for activeShared == 0                 │
//  │                                                                        │
//  │   Writers-preferred: a *queued* exclusive blocks new shared grants,    │
//  │   so staging can never starve a publish.                               │
//  └────────────────────────────────────────────────────────────────────────┘
//
//  ┌─ Priority bands and the bypass rule ───────────────────────────────────┐
//  │                                                                        │
//  │   userInitiated  (2) ──┐                                               │
//  │   foregroundRepair (1) ├─► normally: head of the highest non-empty     │
//  │   background     (0) ──┘   band runs next, FIFO within a band.         │
//  │                                                                        │
//  │   Fairness override: if any queued entry has bypassCount >= 1, the     │
//  │   *oldest* such entry runs next, whatever its band. An entry is        │
//  │   charged a bypass only when it was grantable right then and a         │
//  │   later-arriving entry was chosen over it — a priority pass-over,      │
//  │   never a mode conflict. That makes the bound literal rather than      │
//  │   statistical: bypassCount never reaches 2, so nothing waits behind    │
//  │   more than one later job, with no wall-clock timer anywhere.          │
//  │                                                                        │
//  │     queue: [BG-a]                       → BG-a runs                    │
//  │     UI-1, UI-2 arrive, BG-b queued      → UI-1 runs, BG-b.bypass = 1   │
//  │     UI-3 arrives                        → BG-b runs (bypass >= 1 wins) │
//  │     then                                → UI-2, UI-3 in FIFO           │
//  └────────────────────────────────────────────────────────────────────────┘
//
//  Coalescing: an arriving request whose `coalescingKey` matches one already
//  queued or running joins that one's result instead of running twice.
//
//  Supersession: every dequeue revalidates each queued entry's `Fence` against
//  the live one. A stale entry is removed and resumed with `.superseded`; its
//  body never runs.
//

import Foundation

/// Why a lease was never granted, or granted work was abandoned.
nonisolated enum LocalStoreWriteError: Error, Equatable {
    /// The request's `Fence` no longer matches the live one — the profile
    /// changed, or the enabled-area set was rewritten — so the work it guards
    /// would land in a world it never saw.
    case superseded
    /// Two callers shared a `coalescingKey` but asked for different result
    /// types. The key is meant to identify the work, so this is a programming
    /// error at the call site, not a runtime condition to recover from.
    case coalescedResultTypeMismatch
}

/// Profile plus area generation, captured when a request is made and compared
/// against the live pair on every dequeue (D5). Re-enabling an area bumps the
/// generation, so a job launched before the disable cannot publish into the
/// re-enabled world.
nonisolated struct Fence: Hashable {
    var profile: UUID?
    var areaGeneration: AreaGenerationToken

    /// The fence as the running app sees it right now. Both halves are read
    /// through `AppAreaSettings.areaState`, which is the only thing that can
    /// move the area set and its generation apart.
    static var live: Fence {
        let profile = ActiveProfileStore.current
        return Fence(
            profile: profile,
            areaGeneration: AppAreaSettings.areaState(profileID: profile).generation
        )
    }
}

/// Tracks whether the current task already holds a lease, so the debug assert
/// in `withLease` can catch the reentrant call that would otherwise deadlock.
private nonisolated enum LeaseContext {
    @TaskLocal static var isHeld = false
}

actor LocalStoreWriteCoordinator {
    static let shared = LocalStoreWriteCoordinator()

    nonisolated enum Mode {
        case shared
        case exclusive
    }

    nonisolated enum Priority: Int, Comparable {
        case background = 0
        case foregroundRepair = 1
        case userInitiated = 2

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    nonisolated enum Scope: Hashable {
        case epgPublish(UUID)
        case catalogPublish(UUID)
        case areaRepair(UUID)
        case cloudApply
        case maintenance
    }

    nonisolated struct Request {
        var scope: Scope
        var mode: Mode
        var priority: Priority
        /// Identifies the *work*, not the trigger — see D2. Two requests with
        /// the same key must produce the same result type, because the second
        /// one receives the first one's value.
        var coalescingKey: String
        var fence: Fence

        init(scope: Scope, mode: Mode, priority: Priority, coalescingKey: String, fence: Fence) {
            self.scope = scope
            self.mode = mode
            self.priority = priority
            self.coalescingKey = coalescingKey
            self.fence = fence
        }
    }

    // MARK: - State

    private struct Entry {
        let id: UInt64
        let request: Request
        var bypassCount = 0
        var admission: CheckedContinuation<Void, Error>?
    }

    /// Append-ordered, so array order is arrival order and `id` increases with
    /// index. Both the FIFO tiebreak and "oldest bypassed" rely on that.
    private var queue: [Entry] = []
    /// The followers waiting on one leader's result, keyed by coalescing key.
    /// Present for the whole life of the leader's request, so an arrival can
    /// tell "already running" from "not requested" with one lookup.
    private var coalescers: [String: [CheckedContinuation<any Sendable, Error>]] = [:]
    private var activeShared = 0
    private var activeExclusive = false
    private var nextID: UInt64 = 0
    private let currentFence: @Sendable () -> Fence

    /// Reads the live fence synchronously so that revalidation can happen
    /// inside the dequeue itself rather than across a suspension point, where
    /// a second dequeue could interleave.
    init(currentFence: @escaping @Sendable () -> Fence = { Fence.live }) {
        self.currentFence = currentFence
    }

    // MARK: - Leases

    /// Runs `body` under a lease matching `request`.
    ///
    /// **Not reentrant.** A `withLease` inside another `withLease` on the same
    /// task waits for a lease the caller is itself holding, which never
    /// arrives; the assert below turns that deadlock into a debug crash.
    /// Compose work inside one lease instead of nesting two.
    ///
    /// Throws `.superseded` if the request's fence goes stale before it is
    /// granted, and `CancellationError` if the awaiting task is cancelled
    /// while queued. `body` is not started in either case.
    func withLease<T: Sendable>(
        _ request: Request,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        assert(
            !LeaseContext.isHeld,
            "LocalStoreWriteCoordinator.withLease is not reentrant — \(request.scope) was requested from inside another lease"
        )

        if coalescers[request.coalescingKey] != nil {
            return try await join(request.coalescingKey, as: T.self)
        }

        nextID += 1
        let entry = Entry(id: nextID, request: request)
        coalescers[request.coalescingKey] = []
        queue.append(entry)

        do {
            try await waitForAdmission(entry.id)
        } catch {
            // `settle` has already notified the followers on the supersede and
            // cancel paths; this covers the ones that resume without it, and is
            // a no-op when the key is already gone.
            finishCoalescing(request.coalescingKey, with: .failure(error))
            throw error
        }

        do {
            let value = try await LeaseContext.$isHeld.withValue(true) { try await body() }
            release(request.mode)
            finishCoalescing(request.coalescingKey, with: .success(value))
            return value
        } catch {
            release(request.mode)
            finishCoalescing(request.coalescingKey, with: .failure(error))
            throw error
        }
    }

    private func join<T: Sendable>(_ key: String, as _: T.Type) async throws -> T {
        let boxed: any Sendable = try await withCheckedThrowingContinuation { continuation in
            guard coalescers[key] != nil else {
                // The leader settled between the lookup and here. Nothing to
                // join, and no work was skipped, so re-request rather than
                // inventing a result.
                continuation.resume(throwing: LocalStoreWriteError.superseded)
                return
            }
            coalescers[key]?.append(continuation)
        }
        guard let typed = boxed as? T else { throw LocalStoreWriteError.coalescedResultTypeMismatch }
        return typed
    }

    private func waitForAdmission(_ id: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard let index = queue.firstIndex(where: { $0.id == id }) else {
                    continuation.resume(throwing: LocalStoreWriteError.superseded)
                    return
                }
                queue[index].admission = continuation
                pump()
            }
        } onCancel: {
            Task { await self.abandonQueued(id, error: CancellationError()) }
        }
    }

    private func release(_ mode: Mode) {
        switch mode {
        case .shared: activeShared = max(0, activeShared - 1)
        case .exclusive: activeExclusive = false
        }
        pump()
    }

    private func finishCoalescing(_ key: String, with outcome: Result<any Sendable, Error>) {
        guard let waiters = coalescers.removeValue(forKey: key) else { return }
        for waiter in waiters {
            waiter.resume(with: outcome)
        }
    }

    // MARK: - Dequeue

    private func pump() {
        supersedeStaleEntries()
        while admitNext() {}
    }

    /// Fence revalidation, run on every dequeue. A queued entry whose captured
    /// fence no longer matches the live one is dropped before it can execute.
    ///
    /// Every stale entry leaves the queue before anything is admitted: settling
    /// them one at a time would let an admission run between two removals and
    /// grant a lease to an entry this same pass was about to supersede.
    private func supersedeStaleEntries() {
        guard !queue.isEmpty else { return }
        let live = currentFence()
        var stale: [Entry] = []
        queue.removeAll { entry in
            guard entry.request.fence != live else { return false }
            stale.append(entry)
            return true
        }
        for entry in stale {
            settle(entry, error: LocalStoreWriteError.superseded)
        }
    }

    /// Drops a still-queued entry — the task awaiting it was cancelled — and
    /// re-pumps, because removing a queued exclusive can unblock shared grants.
    private func abandonQueued(_ id: UInt64, error: Error) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        settle(queue.remove(at: index), error: error)
        pump()
    }

    private func settle(_ entry: Entry, error: Error) {
        finishCoalescing(entry.request.coalescingKey, with: .failure(error))
        entry.admission?.resume(throwing: error)
    }

    /// Bypassed entries first, oldest first; then the remaining entries by
    /// band, FIFO within a band. `sorted` is not guaranteed stable, so arrival
    /// order is an explicit tiebreak rather than an assumption.
    private func selectionOrder() -> [Int] {
        let bypassed = queue.indices.filter { queue[$0].bypassCount >= 1 }
        let rest = queue.indices.filter { queue[$0].bypassCount == 0 }.sorted { lhs, rhs in
            let left = queue[lhs].request.priority
            let right = queue[rhs].request.priority
            return left == right ? lhs < rhs : left > right
        }
        return bypassed + rest
    }

    private func canGrant(_ mode: Mode) -> Bool {
        guard !activeExclusive else { return false }
        switch mode {
        case .exclusive: return activeShared == 0
        case .shared: return !queue.contains { $0.request.mode == .exclusive }
        }
    }

    private func admitNext() -> Bool {
        guard let chosen = selectionOrder().first(where: { canGrant(queue[$0].request.mode) }) else {
            return false
        }
        let entry = queue[chosen]

        // Charge a bypass to everything that arrived earlier, is still queued,
        // and could have been granted in this same pass. An entry blocked by a
        // mode conflict was not passed over for priority, so it is not charged
        // — that is what keeps the bound at one rather than letting a shared
        // entry accumulate bypasses behind a queued exclusive it must yield to.
        for index in queue.indices where queue[index].id < entry.id && canGrant(queue[index].request.mode) {
            queue[index].bypassCount += 1
            highWaterBypassCount = max(highWaterBypassCount, queue[index].bypassCount)
        }

        queue.remove(at: chosen)
        switch entry.request.mode {
        case .shared: activeShared += 1
        case .exclusive: activeExclusive = true
        }
        entry.admission?.resume()
        return true
    }

    // MARK: - Introspection

    /// The largest `bypassCount` any entry has reached. Gate G5's bound is
    /// exactly `highWaterBypassCount <= 1`, which is why it is a stored high
    /// water mark rather than something a test has to sample at the right
    /// moment.
    private(set) var highWaterBypassCount = 0

    /// Entries waiting for admission, leaders only — coalesced followers are
    /// not queued.
    var queueDepth: Int {
        queue.count
    }

    /// Followers currently attached to `key`'s leader.
    func coalescedWaiterCount(forKey key: String) -> Int {
        coalescers[key]?.count ?? 0
    }
}

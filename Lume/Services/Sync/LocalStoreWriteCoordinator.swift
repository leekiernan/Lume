//
//  LocalStoreWriteCoordinator.swift
//  Lume
//
//  Serialises the EPG guide's writes to the local store: each source's
//  snapshot publication and the legacy-snapshot retirement run under an
//  exclusive lease, one at a time, so a reader never observes half of two
//  guide snapshots at once. Only `EPGSyncManager` takes leases today; catalog
//  syncs, area repair and the cloud reconcile write without it.
//
//  This is a queue with an admission rule, not a framework. It grants leases;
//  it never touches the store itself. Callers keep owning their own work and
//  their own fence revalidation immediately before `save()`.
//
//  Admission: one lease at a time, FIFO in arrival order.
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
    /// The stable area-set value closes the cross-process observation hole:
    /// another process can observe the generation write before the legacy raw
    /// preference write. A generation alone would let that mixed pair pass;
    /// matching the set as well makes the eventual raw write supersede it.
    var areaFingerprint: String

    init(profile: UUID?, areaGeneration: AreaGenerationToken, areaFingerprint: String = "") {
        self.profile = profile
        self.areaGeneration = areaGeneration
        self.areaFingerprint = areaFingerprint
    }

    /// The fence as the running app sees it right now. Both halves are read
    /// through `AppAreaSettings.areaState`, which is the only thing that can
    /// move the area set and its generation apart.
    static var live: Fence {
        let profile = ActiveProfileStore.current
        let areaState = AppAreaSettings.areaState(profileID: profile)
        return Fence(
            profile: profile,
            areaGeneration: areaState.generation,
            areaFingerprint: areaState.disabledRaw
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

    /// Every lease is exclusive. A shared (staging) mode and priority bands
    /// were designed for callers that never adopted the coordinator; the
    /// single-case enums keep the request shape the EPG call sites use.
    nonisolated enum Mode {
        case exclusive
    }

    nonisolated enum Priority {
        case background
    }

    nonisolated enum Scope: Hashable {
        case epgPublish(UUID)
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
        let cancellation: CancellationFlag
        var admission: CheckedContinuation<Void, Error>?
    }

    /// Cancellation handlers run outside this actor. Keeping the bit behind a
    /// lock lets admission observe cancellation even when its cleanup task has
    /// not reached the actor yet.
    private final nonisolated class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// Append-ordered, so array order is arrival order — the admission order.
    private var queue: [Entry] = []
    /// The followers waiting on one leader's result, keyed by coalescing key.
    /// Present for the whole life of the leader's request, so an arrival can
    /// tell "already running" from "not requested" with one lookup.
    private struct Follower {
        let id: UInt64
        let continuation: CheckedContinuation<any Sendable, Error>
    }

    private var coalescers: [String: [Follower]] = [:]
    private var isLeased = false
    private var nextID: UInt64 = 0
    private var nextFollowerID: UInt64 = 0
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
        let entry = Entry(id: nextID, request: request, cancellation: CancellationFlag())
        coalescers[request.coalescingKey] = []
        queue.append(entry)

        do {
            try await waitForAdmission(entry.id, cancellation: entry.cancellation)
        } catch {
            // `settle` has already notified the followers on the supersede and
            // cancel paths; this covers the ones that resume without it, and is
            // a no-op when the key is already gone.
            finishCoalescing(request.coalescingKey, with: .failure(error))
            throw error
        }

        if Task.isCancelled {
            let error = CancellationError()
            finishCoalescing(request.coalescingKey, with: .failure(error))
            release()
            throw error
        }

        do {
            let value = try await LeaseContext.$isHeld.withValue(true) { try await body() }
            release()
            finishCoalescing(request.coalescingKey, with: .success(value))
            return value
        } catch {
            release()
            finishCoalescing(request.coalescingKey, with: .failure(error))
            throw error
        }
    }

    private func join<T: Sendable>(_ key: String, as _: T.Type) async throws -> T {
        nextFollowerID += 1
        let followerID = nextFollowerID
        let cancellation = CancellationFlag()
        let boxed: any Sendable = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard coalescers[key] != nil else {
                    // The leader settled between the lookup and here. Nothing to
                    // join, and no work was skipped, so re-request rather than
                    // inventing a result.
                    continuation.resume(throwing: LocalStoreWriteError.superseded)
                    return
                }
                guard !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                coalescers[key]?.append(Follower(id: followerID, continuation: continuation))
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelFollower(key: key, id: followerID) }
        }
        guard let typed = boxed as? T else { throw LocalStoreWriteError.coalescedResultTypeMismatch }
        return typed
    }

    /// A follower must not stay retained behind a long-running leader after
    /// its caller has gone away. Removal and resumption happen in the same
    /// actor turn, making the continuation single-owner.
    private func cancelFollower(key: String, id: UInt64) {
        guard var followers = coalescers[key],
              let index = followers.firstIndex(where: { $0.id == id })
        else { return }
        let follower = followers.remove(at: index)
        coalescers[key] = followers
        follower.continuation.resume(throwing: CancellationError())
    }

    private func waitForAdmission(_ id: UInt64, cancellation: CancellationFlag) async throws {
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
            cancellation.cancel()
            Task { await self.abandonQueued(id, error: CancellationError()) }
        }
    }

    private func release() {
        isLeased = false
        pump()
    }

    private func finishCoalescing(_ key: String, with outcome: Result<any Sendable, Error>) {
        guard let waiters = coalescers.removeValue(forKey: key) else { return }
        for waiter in waiters {
            waiter.continuation.resume(with: outcome)
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
    /// re-pumps so the entry behind it is admitted if the lease is free.
    private func abandonQueued(_ id: UInt64, error: Error) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        settle(queue.remove(at: index), error: error)
        pump()
    }

    private func settle(_ entry: Entry, error: Error) {
        finishCoalescing(entry.request.coalescingKey, with: .failure(error))
        entry.admission?.resume(throwing: error)
    }

    private func admitNext() -> Bool {
        guard !isLeased, !queue.isEmpty else { return false }
        let entry = queue[0]

        // The cancellation handler sets this flag synchronously, but its actor
        // cleanup arrives asynchronously. Do not grant a lease in that gap.
        guard !entry.cancellation.isCancelled else {
            queue.removeFirst()
            settle(entry, error: CancellationError())
            return true
        }

        queue.removeFirst()
        isLeased = true
        entry.admission?.resume()
        return true
    }

    // MARK: - Introspection

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

import Foundation
@testable import Lume
import Testing

/// A gate the test opens by hand. Lease bodies block on a value the test
/// controls rather than on elapsed time, so nothing here sleeps and the
/// interleaving under test is the one that is asserted.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

/// Records the order bodies actually executed in.
private actor Recorder {
    private(set) var entries: [String] = []

    func record(_ label: String) {
        entries.append(label)
    }
}

/// The live fence the coordinator reads, which the test can move under it.
private final nonisolated class FenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Fence

    init(_ value: Fence) {
        self.value = value
    }

    var current: Fence {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}

/// `nonisolated` so the tests exercise the coordinator the way the sync engine
/// does — off the main actor — rather than serialising every step through it.
@Suite("LocalStoreWriteCoordinator")
nonisolated struct LocalStoreWriteCoordinatorTests {
    private static let fence = Fence(profile: nil, areaGeneration: .initial)

    private func request(
        _ key: String,
        mode: LocalStoreWriteCoordinator.Mode = .exclusive,
        priority: LocalStoreWriteCoordinator.Priority = .userInitiated,
        fence: Fence = LocalStoreWriteCoordinatorTests.fence
    ) -> LocalStoreWriteCoordinator.Request {
        LocalStoreWriteCoordinator.Request(
            scope: .maintenance,
            mode: mode,
            priority: priority,
            coalescingKey: key,
            fence: fence
        )
    }

    /// Yields until `condition` holds. Bounded, so a regression fails the test
    /// instead of hanging the suite — there is no wall-clock wait involved.
    private func settle(until condition: () async -> Bool) async -> Bool {
        for _ in 0 ..< 10000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    /// Takes the exclusive lease and holds it until the returned gate opens, so
    /// everything requested afterwards is provably *queued* rather than racing.
    private func holdLease(
        on coordinator: LocalStoreWriteCoordinator,
        fence: Fence = LocalStoreWriteCoordinatorTests.fence
    ) async -> (release: Gate, finished: Task<Void, Error>) {
        let started = Gate()
        let release = Gate()
        let blocker = request("blocker", fence: fence)
        let finished = Task.detached {
            try await coordinator.withLease(blocker) {
                await started.open()
                await release.wait()
            }
        }
        await started.wait()
        return (release, finished)
    }

    // MARK: - T-W6

    @Test
    func `duplicate triggers sharing a coalescing key execute once (T-W6)`() async throws {
        let coordinator = LocalStoreWriteCoordinator(currentFence: { Self.fence })
        let executions = Recorder()
        let held = await holdLease(on: coordinator)

        let key = "epg-publish"
        let duplicate = request(key)
        let leader = Task.detached {
            try await coordinator.withLease(duplicate) {
                await executions.record("ran")
                return 7
            }
        }
        #expect(await settle(until: { await coordinator.queueDepth == 1 }))

        let follower = Task.detached {
            try await coordinator.withLease(duplicate) {
                await executions.record("ran")
                return 7
            }
        }
        #expect(await settle(until: { await coordinator.coalescedWaiterCount(forKey: key) == 1 }))

        await held.release.open()
        try await held.finished.value

        // One execution, and the follower receives the leader's value rather
        // than a second run's.
        #expect(try await leader.value == 7)
        #expect(try await follower.value == 7)
        #expect(await executions.entries == ["ran"])
    }

    // MARK: - T-W7

    @Test
    func `a queued entry whose fence goes stale is superseded, never executed (T-W7)`() async throws {
        let box = FenceBox(Self.fence)
        let coordinator = LocalStoreWriteCoordinator(currentFence: { box.current })
        let executions = Recorder()
        let held = await holdLease(on: coordinator)

        let stale = request("catalog-publish")
        let queued = Task.detached {
            try await coordinator.withLease(stale) {
                await executions.record("queued")
            }
        }
        #expect(await settle(until: { await coordinator.queueDepth == 1 }))

        // The area set is rewritten while the entry waits: its captured fence
        // now describes a world that no longer exists.
        box.current = Fence(profile: nil, areaGeneration: Self.fence.areaGeneration.bumped())

        await held.release.open()
        try await held.finished.value

        await #expect(throws: LocalStoreWriteError.superseded) { try await queued.value }
        #expect(await executions.entries.isEmpty)
        #expect(await coordinator.queueDepth == 0)
    }

    @Test
    func `a cancelled queued leader never starts its body`() async throws {
        let coordinator = LocalStoreWriteCoordinator(currentFence: { Self.fence })
        let executions = Recorder()
        let held = await holdLease(on: coordinator)
        let request = request("cancelled")

        let queued = Task.detached {
            try await coordinator.withLease(request) {
                await executions.record("ran")
            }
        }
        #expect(await settle(until: { await coordinator.queueDepth == 1 }))

        // Cancel while the entry is still queued, then release immediately.
        // Admission must see the cancellation bit even if cleanup has not yet
        // won the race to the coordinator actor.
        queued.cancel()
        await held.release.open()
        try await held.finished.value

        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await executions.entries.isEmpty)
    }

    // MARK: - T-W8 (gate G5)

    /// The bound the plan claims — "cannot be bypassed by more than one later
    /// equal- or lower-priority job" — stated as the coordinator's own counter,
    /// under a queue that is never empty while the background entry waits.
    @Test
    func `no queued entry is bypassed twice under saturating user-initiated load (T-W8, gate G5)`() async throws {
        let coordinator = LocalStoreWriteCoordinator(currentFence: { Self.fence })
        let order = Recorder()
        let held = await holdLease(on: coordinator)

        // Background work queues first, so FIFO alone would run it next.
        let backgroundRequest = request("bg", priority: .background)
        let background = Task.detached {
            try await coordinator.withLease(backgroundRequest) {
                await order.record("bg")
            }
        }
        #expect(await settle(until: { await coordinator.queueDepth == 1 }))

        // A user-initiated burst arrives behind it and outranks it. The first
        // of them holds the lease open so later arrivals land mid-drain.
        let firstUserJob = Gate()
        let firstUserJobStarted = Gate()
        let firstUserRequest = request("ui-1")
        let ui1 = Task.detached {
            try await coordinator.withLease(firstUserRequest) {
                await firstUserJobStarted.open()
                await firstUserJob.wait()
                await order.record("ui-1")
            }
        }
        #expect(await settle(until: { await coordinator.queueDepth == 2 }))

        var burst: [Task<Void, Error>] = []
        for index in 2 ... 3 {
            let queued = request("ui-\(index)")
            let label = "ui-\(index)"
            burst.append(Task.detached {
                try await coordinator.withLease(queued) { await order.record(label) }
            })
            #expect(await settle(until: { await coordinator.queueDepth == index + 1 }))
        }

        await held.release.open()
        try await held.finished.value

        // ui-1 wins the first pass and charges the background entry its one
        // permitted bypass.
        await firstUserJobStarted.wait()
        #expect(await coordinator.highWaterBypassCount == 1)

        // More user-initiated work arrives while the background entry waits —
        // the walkthrough's "UI-3 arrives". It must not push it back again.
        for index in 4 ... 5 {
            let queued = request("ui-\(index)")
            let label = "ui-\(index)"
            burst.append(Task.detached {
                try await coordinator.withLease(queued) { await order.record(label) }
            })
            #expect(await settle(until: { await coordinator.queueDepth == index }))
        }

        await firstUserJob.open()
        try await ui1.value
        for task in burst {
            try await task.value
        }
        try await background.value

        #expect(await coordinator.highWaterBypassCount == 1)
        #expect(await order.entries == ["ui-1", "bg", "ui-2", "ui-3", "ui-4", "ui-5"])
    }

    // MARK: - Exclusion

    /// The shape the bypass bound rests on: a queued exclusive stops new shared
    /// grants, so a background staging pass cannot hold a publish off forever.
    @Test
    func `a queued exclusive request blocks new shared grants`() async throws {
        let coordinator = LocalStoreWriteCoordinator(currentFence: { Self.fence })
        let order = Recorder()
        let firstShared = Gate()
        let firstSharedStarted = Gate()

        let stagingA = request("staging-a", mode: .shared, priority: .background)
        let staging = Task.detached {
            try await coordinator.withLease(stagingA) {
                await firstSharedStarted.open()
                await firstShared.wait()
                await order.record("staging-a")
            }
        }
        await firstSharedStarted.wait()

        let publishRequest = request("publish", mode: .exclusive)
        let publish = Task.detached {
            try await coordinator.withLease(publishRequest) { await order.record("publish") }
        }
        #expect(await settle(until: { await coordinator.queueDepth == 1 }))

        let stagingB = request("staging-b", mode: .shared, priority: .background)
        let latecomer = Task.detached {
            try await coordinator.withLease(stagingB) { await order.record("staging-b") }
        }
        #expect(await settle(until: { await coordinator.queueDepth == 2 }))

        await firstShared.open()
        try await staging.value
        try await publish.value
        try await latecomer.value

        // The late shared request queued behind the waiting exclusive instead
        // of joining the in-flight shared grant and deferring the publish.
        #expect(await order.entries == ["staging-a", "publish", "staging-b"])
        // Yielding to a waiting exclusive is a mode conflict, not a priority
        // pass-over, so it is not charged as a bypass.
        #expect(await coordinator.highWaterBypassCount == 0)
    }
}

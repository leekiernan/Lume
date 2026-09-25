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
        fence: Fence = LocalStoreWriteCoordinatorTests.fence
    ) -> LocalStoreWriteCoordinator.Request {
        LocalStoreWriteCoordinator.Request(
            scope: .maintenance,
            mode: .exclusive,
            priority: .background,
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

    @Test
    func `a cancelled coalesced follower is removed and resumed before its leader finishes`() async throws {
        let coordinator = LocalStoreWriteCoordinator(currentFence: { Self.fence })
        let started = Gate()
        let release = Gate()
        let request = request("coalesced-cancellation")
        let leader = Task.detached {
            try await coordinator.withLease(request) {
                await started.open()
                await release.wait()
                return 1
            }
        }
        await started.wait()

        let follower = Task.detached {
            try await coordinator.withLease(request) { 2 }
        }
        #expect(await settle(until: { await coordinator.coalescedWaiterCount(forKey: "coalesced-cancellation") == 1 }))
        follower.cancel()
        #expect(await settle(until: { await coordinator.coalescedWaiterCount(forKey: "coalesced-cancellation") == 0 }))
        await #expect(throws: CancellationError.self) { try await follower.value }

        await release.open()
        #expect(try await leader.value == 1)
    }

    @Test
    func `same generation with a changed area fingerprint is superseded`() async throws {
        let captured = Fence(profile: nil, areaGeneration: .initial.bumped(), areaFingerprint: "")
        let box = FenceBox(captured)
        let coordinator = LocalStoreWriteCoordinator(currentFence: { box.current })
        let held = await holdLease(on: coordinator, fence: captured)
        let executions = Recorder()
        let queuedRequest = request("fingerprint", fence: captured)
        let queued = Task.detached {
            try await coordinator.withLease(queuedRequest) {
                await executions.record("ran")
            }
        }
        #expect(await settle(until: { await coordinator.queueDepth == 1 }))

        // Models the second process observing generation N before the old raw
        // area set is replaced: the generation is unchanged, but the pair is not.
        box.current = Fence(profile: nil, areaGeneration: captured.areaGeneration, areaFingerprint: "liveTV")
        await held.release.open()
        try await held.finished.value

        await #expect(throws: LocalStoreWriteError.superseded) { try await queued.value }
        #expect(await executions.entries.isEmpty)
    }

    // MARK: - Admission order

    /// One lease at a time, granted in arrival order.
    @Test
    func `queued requests run one at a time in arrival order`() async throws {
        let coordinator = LocalStoreWriteCoordinator(currentFence: { Self.fence })
        let order = Recorder()
        let held = await holdLease(on: coordinator)

        var queued: [Task<Void, Error>] = []
        for index in 1 ... 3 {
            let next = request("job-\(index)")
            let label = "job-\(index)"
            queued.append(Task.detached {
                try await coordinator.withLease(next) { await order.record(label) }
            })
            #expect(await settle(until: { await coordinator.queueDepth == index }))
        }

        await held.release.open()
        try await held.finished.value
        for task in queued {
            try await task.value
        }

        #expect(await order.entries == ["job-1", "job-2", "job-3"])
    }
}

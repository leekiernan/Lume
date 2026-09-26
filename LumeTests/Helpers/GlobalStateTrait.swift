//
//  GlobalStateTrait.swift
//  LumeTests
//
//  `@Suite(.globalState)` / `@Test(.globalState)`: runs each test case while
//  holding one process-wide lock, so tests that touch process-global state
//  never overlap.
//
//  Swift Testing runs suites (and the tests inside them) in parallel, and
//  `.serialized` only orders the tests *within* one suite. Several services
//  deliberately keep device-local state in process-wide places —
//  `UserDefaults.standard` (`ActiveProfileStore`, the m3u/WebDAV digests,
//  `WatchProgressBuffer`, …), the keychain, and `.shared` singletons — so a
//  suite that writes one of them can break any other suite that reads it,
//  depending only on scheduling. Every suite that reads or writes such state
//  takes this trait; everything else keeps running in parallel around them.
//
//  Prefer making a suite hermetic instead when the code under test can be
//  handed its own `UserDefaults(suiteName:)` or store — this trait is for
//  state that has no injection point.
//

import Testing

/// Serializes every test case that carries it, across all suites.
///
/// Recursive, so applying it to a suite covers each test (and each argument of
/// a parameterized test) inside it. The lock is taken per test case rather
/// than once per suite: that also excludes a suite's own tests from each
/// other, which is usually what state-sharing tests need anyway. Keep
/// `.serialized` alongside it where tests additionally rely on running in
/// declaration order.
nonisolated struct GlobalStateTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func scopeProvider(for _: Test, testCase: Test.Case?) -> Self? {
        // Only individual test cases hold the lock: a suite-level scope would
        // hold it across the suite's children and deadlock them.
        testCase == nil ? nil : self
    }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await GlobalStateLock.withLock(function)
    }
}

extension Trait where Self == GlobalStateTrait {
    /// The test reads or writes process-global state (`UserDefaults.standard`,
    /// `ActiveProfileStore`, the keychain, a `.shared` singleton), so it must
    /// not run concurrently with any other test that does.
    static var globalState: Self {
        Self()
    }
}

/// A FIFO async mutex. Waiters suspend on a continuation instead of blocking a
/// thread, so a queue of waiting tests never starves Swift Testing's
/// cooperative pool.
actor GlobalStateLock {
    private static let shared = GlobalStateLock()

    /// Set while the current task holds the lock, so a test that inherits the
    /// trait from its suite *and* declares it itself doesn't wait on itself.
    @TaskLocal private static var isHeld = false

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static func withLock(_ body: @concurrent @Sendable () async throws -> Void) async throws {
        if isHeld {
            try await body()
            return
        }
        await shared.acquire()
        do {
            try await $isHeld.withValue(true) { try await body() }
        } catch {
            await shared.release()
            throw error
        }
        await shared.release()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        // Ownership passes straight to the next waiter; the lock only opens
        // when nobody is queued.
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

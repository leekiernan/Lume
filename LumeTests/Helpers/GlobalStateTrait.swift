//
//  GlobalStateTrait.swift
//  LumeTests
//
//  `@Suite(.globalState)` / `@Test(.globalState)`: runs each test case while
//  holding one process-wide lock, so tests that touch process-global state
//  never overlap. `.readsGlobalState` takes the same lock shared: readers run
//  alongside each other, never alongside a writer.
//
//  Swift Testing runs suites (and the tests inside them) in parallel, and
//  `.serialized` only orders the tests *within* one suite. Several services
//  deliberately keep device-local state in process-wide places —
//  `UserDefaults.standard` (`ActiveProfileStore`, the m3u/WebDAV digests,
//  `WatchProgressBuffer`, …), the keychain, and `.shared` singletons — so a
//  suite that writes one of them can break any other suite that reads it,
//  depending only on scheduling. Every suite that writes such state takes
//  `.globalState`; one that only reads it (e.g. a sync whose area gating and
//  write fence read the active profile) takes `.readsGlobalState`; everything
//  else keeps running in parallel around them.
//
//  Prefer making a suite hermetic instead when the code under test can be
//  handed its own `UserDefaults(suiteName:)` or store — this trait is for
//  state that has no injection point.
//

import Testing

/// Runs every test case that carries it under the process-wide global-state
/// lock — exclusively (`.globalState`) or shared with other readers
/// (`.readsGlobalState`).
///
/// Recursive, so applying it to a suite covers each test (and each argument of
/// a parameterized test) inside it. The lock is taken per test case rather
/// than once per suite: that also excludes a suite's own tests from each
/// other, which is usually what state-sharing tests need anyway. Keep
/// `.serialized` alongside it where tests additionally rely on running in
/// declaration order.
nonisolated struct GlobalStateTrait: TestTrait, SuiteTrait, TestScoping {
    enum Access {
        /// Writes (or wipes) process-global state: runs alone.
        case exclusive
        /// Only reads it: runs alongside other readers, never alongside a writer.
        case shared
    }

    var access: Access

    var isRecursive: Bool {
        true
    }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        // Only individual test cases hold the lock: a suite-level scope would
        // hold it across the suite's children and deadlock them.
        guard testCase != nil else { return nil }
        // A shared hold can't be upgraded, so when a test carries both forms
        // (a reading suite, a writing test) only the exclusive one acts.
        if access == .shared,
           test.traits.contains(where: { ($0 as? Self)?.access == .exclusive })
        {
            return nil
        }
        return self
    }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await GlobalStateLock.withLock(access, function)
    }
}

extension Trait where Self == GlobalStateTrait {
    /// The test writes process-global state (`UserDefaults.standard`,
    /// `ActiveProfileStore`, the keychain, a `.shared` singleton), so it must
    /// not run concurrently with any other test that reads or writes it.
    static var globalState: Self {
        Self(access: .exclusive)
    }

    /// The test only reads process-global state, so it may overlap other
    /// readers but never a test that writes it.
    static var readsGlobalState: Self {
        Self(access: .shared)
    }
}

/// A FIFO async reader/writer lock. Waiters suspend on a continuation instead
/// of blocking a thread, so a queue of waiting tests never starves Swift
/// Testing's cooperative pool. Strict arrival order also keeps a stream of
/// readers from starving a writer.
actor GlobalStateLock {
    private static let shared = GlobalStateLock()

    /// What the current task already holds, so a test that inherits the trait
    /// from its suite *and* declares it itself doesn't wait on itself.
    @TaskLocal private static var held: GlobalStateTrait.Access?

    private var readers = 0
    private var hasWriter = false
    private var waiters: [(access: GlobalStateTrait.Access, continuation: CheckedContinuation<Void, Never>)] = []

    static func withLock(
        _ access: GlobalStateTrait.Access,
        _ body: @concurrent @Sendable () async throws -> Void
    ) async throws {
        if held == .exclusive || (held == .shared && access == .shared) {
            try await body()
            return
        }
        await shared.acquire(access)
        do {
            try await $held.withValue(access) { try await body() }
        } catch {
            await shared.release(access)
            throw error
        }
        await shared.release(access)
    }

    private func acquire(_ access: GlobalStateTrait.Access) async {
        if waiters.isEmpty, canGrant(access) {
            take(access)
            return
        }
        await withCheckedContinuation { waiters.append((access, $0)) }
    }

    private func release(_ access: GlobalStateTrait.Access) {
        switch access {
        case .exclusive: hasWriter = false
        case .shared: readers -= 1
        }
        // Wake waiters in arrival order: a run of readers together, or one
        // writer once the lock is fully free.
        while let next = waiters.first, canGrant(next.access) {
            waiters.removeFirst()
            take(next.access)
            next.continuation.resume()
        }
    }

    private func canGrant(_ access: GlobalStateTrait.Access) -> Bool {
        switch access {
        case .exclusive: !hasWriter && readers == 0
        case .shared: !hasWriter
        }
    }

    private func take(_ access: GlobalStateTrait.Access) {
        switch access {
        case .exclusive: hasWriter = true
        case .shared: readers += 1
        }
    }
}

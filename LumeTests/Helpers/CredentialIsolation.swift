//
//  CredentialIsolation.swift
//  LumeTests
//
//  Keeps every test away from the real keychain.
//
//  The unit tests run hosted inside the real Lume.app, so the credential stores
//  (`TraktTokenStore`, `SimklTokenStore`, `ParentalControlsStore`,
//  `OpenSubtitlesSessionStore`) would otherwise read and write the developer's
//  actual sign-ins — a test that cleared "the Trakt token" once signed every
//  device out through the iCloud credential reconcile.
//
//  Two layers:
//
//  1. `CredentialIsolation.c` runs `lumeTestsInstallCredentialIsolation()` as a
//     load-time constructor of this bundle, before any test (or any other code
//     in the bundle) can run. It installs an in-memory `CredentialBackend` for
//     the whole process, so even a test that never thinks about credentials —
//     any `CloudSyncEngine.reconcile()` reads the Trakt, Simkl and PIN stores —
//     cannot reach a real keychain item.
//  2. `withIsolatedCredentials` gives one test its own empty storage and
//     defaults, bound to its task, so credential tests don't share state with
//     each other and can run in parallel.
//

import Foundation
@testable import Lume
import os
import Testing

/// A keychain stand-in: items live in a dictionary. `isLocked` makes every item
/// unreadable, like a `WhenUnlocked` keychain item on a locked device.
final nonisolated class InMemoryCredentialStorage: CredentialStorage {
    private struct State {
        var items: [CredentialItem: Data] = [:]
        var isLocked = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isLocked: Bool {
        get { state.withLock { $0.isLocked } }
        set { state.withLock { $0.isLocked = newValue } }
    }

    /// The raw item, bypassing the lock — for assertions.
    func storedData(service: String) -> Data? {
        state.withLock { state in state.items.first { $0.key.service == service }?.value }
    }

    func read(_ item: CredentialItem) -> CredentialRead {
        state.withLock { state in
            guard !state.isLocked else { return .unavailable }
            return state.items[item].map(CredentialRead.found) ?? .notFound
        }
    }

    func contains(_ item: CredentialItem) -> Bool? {
        state.withLock { state in state.isLocked ? nil : state.items[item] != nil }
    }

    func write(_ data: Data, to item: CredentialItem) -> Bool {
        state.withLock { state in
            guard !state.isLocked else { return false }
            state.items[item] = data
            return true
        }
    }

    func delete(_ item: CredentialItem) -> Bool {
        state.withLock { state in
            guard !state.isLocked else { return false }
            state.items[item] = nil
            return true
        }
    }
}

nonisolated enum CredentialIsolation {
    /// The process-wide stand-in installed at bundle load.
    static let processStorage = InMemoryCredentialStorage()

    /// Resolved lazily (the backend is installed while the bundle is still
    /// loading, too early to create a defaults suite) and emptied on first use,
    /// so nothing carries over from a previous run.
    private static let processDefaults: UserDefaults = {
        let name = "bilipp.LumeTests.credentials"
        // Never `.standard`: a suite named by this bundle always exists.
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

    static func installProcessBackend() {
        CredentialBackend.install(CredentialBackend(storage: processStorage, defaults: { processDefaults }))
    }
}

/// Called from `CredentialIsolation.c`'s load-time constructor.
@_cdecl("lumeTestsInstallCredentialIsolation")
nonisolated func lumeTestsInstallCredentialIsolation() {
    CredentialIsolation.installProcessBackend()
    PendingStoreIsolation.install()
}

/// Runs `body` against fresh, empty credential storage and defaults of its own,
/// visible to everything `body` awaits (including a `CloudSyncEngine` actor).
/// The storage is passed in so the test can inspect or lock it.
@discardableResult
func withIsolatedCredentials<R>(
    isolation _: isolated (any Actor)? = #isolation,
    _ body: (InMemoryCredentialStorage) async throws -> R
) async rethrows -> R {
    let storage = InMemoryCredentialStorage()
    let suiteName = "bilipp.LumeTests.credentials.\(UUID().uuidString)"
    // Never `.standard`: a suite named by this bundle always exists.
    let backend = CredentialBackend(storage: storage, defaults: { UserDefaults(suiteName: suiteName)! })
    defer { backend.defaults.removePersistentDomain(forName: suiteName) }
    return try await CredentialBackend.$scoped.withValue(backend) {
        try await body(storage)
    }
}

/// `@Suite(.isolatedCredentials)` / `@Test(.isolatedCredentials)`: every test
/// case runs inside `withIsolatedCredentials`. Reach the storage through
/// `CredentialIsolation.scopedStorage()`.
nonisolated struct IsolatedCredentialsTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func scopeProvider(for _: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await withIsolatedCredentials { _ in try await function() }
    }
}

extension Trait where Self == IsolatedCredentialsTrait {
    static var isolatedCredentials: Self {
        Self()
    }
}

extension CredentialIsolation {
    /// The storage bound by `.isolatedCredentials` / `withIsolatedCredentials`.
    static func scopedStorage() throws -> InMemoryCredentialStorage {
        try #require(CredentialBackend.scoped?.storage as? InMemoryCredentialStorage)
    }
}

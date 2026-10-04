import Foundation
@testable import Lume
import Testing

/// Real importer/store tests use a known account, independent of the installed
/// app. The identity is restored even if assertions throw; no token is written.
nonisolated struct TrackerIdentityFixture: TestTrait, SuiteTrait, TestScoping {
    enum Provider { case trakt, simkl }
    let provider: Provider
    var isRecursive: Bool {
        true
    }

    func scopeProvider(for _: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(for _: Test, testCase _: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        try await GlobalStateLock.withLock(.exclusive) {
            switch provider {
            case .trakt:
                let old = TraktAccountIdentityStore.load()
                defer {
                    if let old { TraktAccountIdentityStore.save(old) } else { TraktAccountIdentityStore.clear() }
                }
                TraktAccountIdentityStore.save(.init(username: "fixture", scope: "trakt:fixture"))
                try await function()
            case .simkl:
                let old = SimklAccountIdentityStore.load()
                defer {
                    if let old { SimklAccountIdentityStore.save(old) } else { SimklAccountIdentityStore.clear() }
                }
                SimklAccountIdentityStore.save(.init(username: "fixture", scope: "simkl:fixture"))
                try await function()
            }
        }
    }
}

extension Trait where Self == TrackerIdentityFixture {
    static func trackerIdentity(_ provider: TrackerIdentityFixture.Provider) -> Self {
        Self(provider: provider)
    }
}

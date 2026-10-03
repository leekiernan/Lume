import Foundation
@testable import Lume
import Testing

/// Fetched tracker history is applied only to the account and profile it was
/// fetched for, with nothing local still waiting to go up.
struct TrackerImportScopeTests {
    private let profile = UUID()
    private var scope: TrackerImportScope {
        TrackerImportScope(account: "a", profileID: profile)
    }

    @Test func `unchanged scope may apply`() {
        #expect(scope.isCurrent(isConnected: true, account: "a", pendingCount: 0, profileID: profile))
    }

    @Test func `a disconnect or another account during the import discards it`() {
        #expect(!scope.isCurrent(isConnected: false, account: "a", pendingCount: 0, profileID: profile))
        #expect(!scope.isCurrent(isConnected: true, account: "b", pendingCount: 0, profileID: profile))
    }

    @Test func `a profile switch during the import discards it`() {
        #expect(!scope.isCurrent(isConnected: true, account: "a", pendingCount: 0, profileID: UUID()))
    }

    @Test func `a local change made during the import discards it`() {
        #expect(!scope.isCurrent(isConnected: true, account: "a", pendingCount: 1, profileID: profile))
    }
}

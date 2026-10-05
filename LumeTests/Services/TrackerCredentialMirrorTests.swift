import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.serialized, .readsGlobalState, .isolatedCredentials)
struct TrackerCredentialMirrorTests {
    enum Provider: CaseIterable {
        case trakt, simkl

        var kind: SyncedCredentialKind {
            self == .trakt ? .trakt : .simkl
        }

        func save(_ access: String, issuedAt: TimeInterval = 100) -> Bool {
            switch self {
            case .trakt: TraktTokenStore.save(Self.trakt(access, issuedAt: issuedAt))
            case .simkl: SimklTokenStore.save(Self.simkl(access, issuedAt: issuedAt))
            }
        }

        func clear(disconnect: Bool = false) -> Bool {
            switch self {
            case .trakt:
                if disconnect { TraktTokenStore.clearForUserDisconnect() } else { TraktTokenStore.clear() }
            case .simkl:
                if disconnect { SimklTokenStore.clearForUserDisconnect() } else { SimklTokenStore.clear() }
            }
        }

        var localAccess: String? {
            switch self {
            case .trakt: TraktTokenStore.load()?.accessToken
            case .simkl: SimklTokenStore.load()?.accessToken
            }
        }

        func insert(_ access: String, issuedAt: TimeInterval, into context: ModelContext) {
            let date = Date(timeIntervalSince1970: issuedAt)
            switch self {
            case .trakt: context.insert(SyncedTraktAccount(tokens: Self.trakt(access, issuedAt: issuedAt), updatedAt: date))
            case .simkl: context.insert(SyncedSimklAccount(tokens: Self.simkl(access, issuedAt: issuedAt), updatedAt: date))
            }
        }

        func cloudAccess(in context: ModelContext) throws -> [String] {
            switch self {
            case .trakt: try context.fetch(FetchDescriptor<SyncedTraktAccount>()).map(\.accessToken)
            case .simkl: try context.fetch(FetchDescriptor<SyncedSimklAccount>()).map(\.accessToken)
            }
        }

        func pending(_ result: CloudSyncReconcileResult) -> Int {
            self == .trakt ? result.traktPending : result.simklPending
        }

        func pushed(_ result: CloudSyncReconcileResult) -> Int {
            self == .trakt ? result.traktPushed : result.simklPushed
        }

        func pulled(_ result: CloudSyncReconcileResult) -> Int {
            self == .trakt ? result.traktPulled : result.simklPulled
        }

        private static func trakt(_ access: String, issuedAt: TimeInterval) -> TraktTokens {
            TraktTokens(accessToken: access, refreshToken: "\(access)-refresh", createdAt: issuedAt, expiresIn: 604_800, scope: "public", tokenType: "Bearer")
        }

        private static func simkl(_ access: String, issuedAt: TimeInterval) -> SimklTokens {
            SimklTokens(accessToken: access, refreshToken: "\(access)-refresh", issuedAt: issuedAt, expiresIn: 604_800, scope: "public", tokenType: "Bearer")
        }
    }

    private func freshShadow() -> CloudSyncShadow {
        CloudSyncShadow(defaults: UserDefaults(suiteName: "cloudsync.tracker-parity.\(UUID().uuidString)")!)
    }

    @Test(arguments: Provider.allCases)
    func `invalid and duplicate mirrors converge on the newest valid authorization`(provider: Provider) async throws {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        provider.insert("old", issuedAt: 100, into: context)
        provider.insert("new", issuedAt: 200, into: context)
        provider.insert("", issuedAt: 300, into: context)
        try context.save()
        let result = await CloudSyncEngine(container: container, shadow: freshShadow()).reconcile()
        #expect(!result.failed)
        #expect(provider.pulled(result) == 1)
        #expect(provider.localAccess == "new")
        #expect(try provider.cloudAccess(in: context) == ["new"])
    }

    @Test(arguments: Provider.allCases)
    func `silent loss restores authorization but explicit disconnect deletes once`(provider: Provider) async throws {
        let container = try makeProfileTestContainer()
        let shadow = freshShadow()
        #expect(provider.save("original"))
        let pushed = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(provider.pushed(pushed) == 1)
        #expect(provider.clear())
        let pulled = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(provider.pulled(pulled) == 1)
        #expect(provider.localAccess == "original")
        #expect(provider.clear(disconnect: true))
        let deleted = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(deleted.credentialDeletionsPushed == [provider.kind])
        #expect(try provider.cloudAccess(in: container.mainContext).isEmpty)
        let settled = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(settled.credentialDeletionsPushed.isEmpty)
    }

    @Test(arguments: Provider.allCases)
    func `locked reads cannot dedupe or mutate mirrors`(provider: Provider) async throws {
        let container = try makeProfileTestContainer()
        provider.insert("old", issuedAt: 100, into: container.mainContext)
        provider.insert("new", issuedAt: 200, into: container.mainContext)
        try container.mainContext.save()
        let storage = try CredentialIsolation.scopedStorage()
        storage.isLocked = true
        let shadow = freshShadow()
        let pending = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(provider.pending(pending) == 1)
        #expect(try provider.cloudAccess(in: container.mainContext).count == 2)
        storage.isLocked = false
        let restored = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(provider.pulled(restored) == 1)
        #expect(provider.localAccess == "new")
    }

    @Test(arguments: Provider.allCases)
    func `a failed store save cannot acknowledge a disconnect`(provider: Provider) async throws {
        let container = try makeProfileTestContainer()
        let shadow = freshShadow()
        #expect(provider.save("original"))
        _ = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(provider.clear(disconnect: true))
        let failing = CloudSyncEngine(container: container, shadow: shadow, saveFailureInjector: { _ in throw CocoaError(.fileWriteUnknown) })
        let failed = await failing.reconcile()
        #expect(failed.failed)
        #expect(CredentialLinkStateStore.state(for: provider.kind).removalPendingPush)
        #expect(try provider.cloudAccess(in: container.mainContext) == ["original"])
        let retried = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(!retried.failed)
        #expect(!CredentialLinkStateStore.state(for: provider.kind).removalPendingPush)
        #expect(try provider.cloudAccess(in: container.mainContext).isEmpty)
    }
}

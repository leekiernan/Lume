//
//  CredentialReconcileTests.swift
//  LumeTests
//
//  "Disconnected by the user" is state, not absence: the iCloud credential
//  reconcile (Trakt, Simkl, parental PIN) only deletes the shared copy when the
//  user removed the credential on this device. A credential that silently
//  vanished from the keychain is restored from the cloud instead.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

// MARK: - Link state transitions

struct CredentialLinkStateTests {
    @Test func `the explicit disconnect makes a removal pending from any state`() {
        for state in [CredentialLinkState.connected, .disconnectedByUser(pendingPush: false), .disconnectedByUser(pendingPush: true)] {
            #expect(state.applying(.userDisconnected) == .disconnectedByUser(pendingPush: true))
        }
    }

    @Test func `pushing the deletion clears the pending flag but remembers the decision`() {
        #expect(CredentialLinkState.disconnectedByUser(pendingPush: true).applying(.deletionPushed) == .disconnectedByUser(pendingPush: false))
        #expect(CredentialLinkState.disconnectedByUser(pendingPush: false).applying(.deletionPushed) == .disconnectedByUser(pendingPush: false))
        #expect(CredentialLinkState.connected.applying(.deletionPushed) == .connected)
    }

    @Test func `storing a credential or a failed removal means connected`() {
        for state in [CredentialLinkState.connected, .disconnectedByUser(pendingPush: false), .disconnectedByUser(pendingPush: true)] {
            #expect(state.applying(.credentialStored) == .connected)
            #expect(state.applying(.removalFailed) == .connected)
        }
    }

    @Test func `only a pending disconnect counts as a removal`() {
        #expect(CredentialLinkState.disconnectedByUser(pendingPush: true).removalPendingPush)
        #expect(!CredentialLinkState.disconnectedByUser(pendingPush: false).removalPendingPush)
        #expect(!CredentialLinkState.connected.removalPendingPush)
    }
}

// MARK: - Pure merge

/// The same decision table, run through each credential's own merge.
struct CredentialReconcilePolicyTests {
    /// One credential's merge, reduced to values `a` / `b` so every kind shares
    /// the table below. Verdicts are mapped back to those names for comparison.
    nonisolated struct Kind: CustomTestStringConvertible {
        let name: String
        let run: @Sendable (_ local: String?, _ cloud: String?, _ shadow: String?, _ state: CredentialLinkState) -> MergeVerdict<String>

        var testDescription: String {
            name
        }
    }

    nonisolated static let kinds: [Kind] = [
        Kind(name: "Trakt") { local, cloud, shadow, state in
            TraktCredentialValues.reconcile(local: trakt(local), cloud: trakt(cloud), shadow: trakt(shadow), linkState: state)
                .mapped { $0.tokens?.accessToken ?? "?" }
        },
        Kind(name: "Simkl") { local, cloud, shadow, state in
            SimklCredentialValues.reconcile(local: simkl(local), cloud: simkl(cloud), shadow: simkl(shadow), linkState: state)
                .mapped { $0.tokens?.accessToken ?? "?" }
        },
        Kind(name: "parental PIN") { local, cloud, shadow, state in
            ParentalPINValues.reconcile(local: pin(local), cloud: pin(cloud), shadow: pin(shadow), linkState: state)
                .mapped(\.hash)
        }
    ]

    @Test(arguments: kinds)
    func `an explicit disconnect propagates`(kind: Kind) {
        #expect(kind.run(nil, "a", "a", .disconnectedByUser(pendingPush: true)) == .pushToCloud(nil))
        // …even over a refresh another device pushed meanwhile.
        #expect(kind.run(nil, "b", "a", .disconnectedByUser(pendingPush: true)) == .pushToCloud(nil))
    }

    @Test(arguments: kinds)
    func `a silently lost credential is restored from the cloud`(kind: Kind) {
        // The incident: the keychain item vanished (a test run, a restore), the
        // cloud still holds the baseline. That is not a disconnect.
        #expect(kind.run(nil, "a", "a", .connected) == .pullToLocal("a"))
        #expect(kind.run(nil, "b", "a", .connected) == .pullToLocal("b"))
        // A disconnect already pushed is no longer pending: a later sign-in on
        // another device reaches this one as before.
        #expect(kind.run(nil, "b", nil, .disconnectedByUser(pendingPush: false)) == .pullToLocal("b"))
    }

    @Test(arguments: kinds)
    func `a new sign-in on this device is pushed`(kind: Kind) {
        #expect(kind.run("a", nil, nil, .connected) == .pushToCloud("a"))
        #expect(kind.run("b", "a", "a", .connected) == .pushToCloud("b"))
    }

    @Test(arguments: kinds)
    func `a first-ever sync pulls the cloud credential`(kind: Kind) {
        #expect(kind.run(nil, "a", nil, .connected) == .pullToLocal("a"))
        // Both sides already agree: just establish the baseline.
        #expect(kind.run("a", "a", nil, .connected) == .pushToCloud("a"))
    }

    @Test(arguments: kinds)
    func `nothing on either side changes nothing`(kind: Kind) {
        #expect(kind.run(nil, nil, nil, .connected) == .noChange)
        // A stale baseline with nothing left on either side is settled, not
        // resurrected.
        #expect(kind.run(nil, nil, "a", .connected) == .pushToCloud(nil))
    }

    @Test(arguments: kinds)
    func `a disconnect on another device still reaches this one`(kind: Kind) {
        #expect(kind.run("a", nil, "a", .connected) == .pullToLocal(nil))
    }

    @Test(arguments: kinds)
    func `a pending disconnect with the credential still present merges normally`(kind: Kind) {
        // The Disconnect path records the decision just before deleting the
        // item; a pass landing in between must not push anything unusual.
        #expect(kind.run("a", "a", "a", .disconnectedByUser(pendingPush: true)) == .noChange)
    }

    private nonisolated static func trakt(_ value: String?) -> TraktCredentialValues? {
        value.map {
            TraktCredentialValues(tokens: TraktTokens(
                accessToken: $0, refreshToken: "\($0)-refresh", createdAt: 100, expiresIn: 604_800, scope: nil, tokenType: nil
            ))
        }
    }

    private nonisolated static func simkl(_ value: String?) -> SimklCredentialValues? {
        value.map {
            SimklCredentialValues(tokens: SimklTokens(
                accessToken: $0, refreshToken: "\($0)-refresh", issuedAt: 100, expiresIn: 604_800, scope: nil, tokenType: nil
            ))
        }
    }

    private nonisolated static func pin(_ value: String?) -> ParentalPINValues? {
        value.map { ParentalPINValues(hash: $0) }
    }
}

private nonisolated extension MergeVerdict {
    func mapped<T: Equatable>(_ transform: (Value) -> T) -> MergeVerdict<T> {
        switch self {
        case .noChange: .noChange
        case let .pushToCloud(value): .pushToCloud(value.map(transform))
        case let .pullToLocal(value): .pullToLocal(value.map(transform))
        case let .writeBoth(value): .writeBoth(transform(value))
        }
    }
}

// MARK: - Engine

/// The full pass against in-memory stores and isolated credential storage.
@MainActor
@Suite(.serialized, .readsGlobalState, .isolatedCredentials)
struct CredentialReconcileEngineTests {
    private func freshShadow() -> CloudSyncShadow {
        CloudSyncShadow(defaults: UserDefaults(suiteName: "cloudsync.credentials.test.\(UUID().uuidString)")!)
    }

    private func makeTokens(_ access: String, createdAt: TimeInterval = 1_700_000_000) -> TraktTokens {
        TraktTokens(accessToken: access, refreshToken: "\(access)-refresh", createdAt: createdAt, expiresIn: 604_800, scope: "public", tokenType: "Bearer")
    }

    /// A device that signed in and synced: the token is local, in the cloud,
    /// and baselined in the shadow.
    private func syncedDevice() async throws -> (container: ModelContainer, shadow: CloudSyncShadow) {
        let container = try makeProfileTestContainer()
        let shadow = freshShadow()
        #expect(TraktTokenStore.save(makeTokens("original")))
        #expect(ParentalControlsStore.save(pin: "1234"))
        let result = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(result.traktPushed == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedTraktAccount>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedParentalPIN>()).count == 1)
        return (container, shadow)
    }

    @Test func `a keychain that lost the token is restored, and the cloud keeps it`() async throws {
        let (container, shadow) = try await syncedDevice()

        // Silent loss: the items go without anyone pressing Disconnect.
        #expect(TraktTokenStore.clear())
        #expect(ParentalControlsStore.clear())

        let result = await CloudSyncEngine(container: container, shadow: shadow).reconcile()

        #expect(result.traktPulled == 1)
        #expect(TraktTokenStore.load()?.accessToken == "original")
        #expect(ParentalControlsStore.verify(pin: "1234"))
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedTraktAccount>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedParentalPIN>()).count == 1)
        #expect(result.credentialDeletionsPushed.isEmpty)
    }

    @Test func `an explicit disconnect deletes the shared copy once, then settles`() async throws {
        let (container, shadow) = try await syncedDevice()

        #expect(TraktTokenStore.clearForUserDisconnect())
        #expect(ParentalControlsStore.clearForUserRemoval())
        #expect(CredentialLinkStateStore.state(for: .trakt) == .disconnectedByUser(pendingPush: true))

        let result = await CloudSyncEngine(container: container, shadow: shadow).reconcile()

        #expect(result.credentialDeletionsPushed == [.trakt, .parentalPIN])
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedTraktAccount>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedParentalPIN>()).isEmpty)
        #expect(CredentialLinkStateStore.state(for: .trakt) == .disconnectedByUser(pendingPush: false))
        #expect(CredentialLinkStateStore.state(for: .parentalPIN) == .disconnectedByUser(pendingPush: false))

        // A sign-in on another device afterwards still reaches this one.
        container.mainContext.insert(SyncedTraktAccount(tokens: makeTokens("elsewhere")))
        try container.mainContext.save()
        _ = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(TraktTokenStore.load()?.accessToken == "elsewhere")
        #expect(CredentialLinkStateStore.state(for: .trakt) == .connected)
    }

    @Test func `a failed save leaves the disconnect pending for the retry`() async throws {
        let (container, shadow) = try await syncedDevice()
        #expect(TraktTokenStore.clearForUserDisconnect())

        let failing = CloudSyncEngine(container: container, shadow: shadow, saveFailureInjector: { _ in
            throw CocoaError(.fileWriteUnknown)
        })
        let failed = await failing.reconcile()
        #expect(failed.failed)
        #expect(CredentialLinkStateStore.state(for: .trakt) == .disconnectedByUser(pendingPush: true))

        _ = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedTraktAccount>()).isEmpty)
        #expect(TraktTokenStore.load() == nil)
    }

    @Test func `a new sign-in clears a past disconnect and is pushed`() async throws {
        let container = try makeProfileTestContainer()
        let shadow = freshShadow()
        #expect(TraktTokenStore.clearForUserDisconnect())
        #expect(TraktTokenStore.save(makeTokens("fresh")))
        #expect(CredentialLinkStateStore.state(for: .trakt) == .connected)

        let result = await CloudSyncEngine(container: container, shadow: shadow).reconcile()
        #expect(result.traktPushed == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedTraktAccount>()).first?.accessToken == "fresh")
    }

    @Test func `a locked keychain leaves every side untouched`() async throws {
        let (container, shadow) = try await syncedDevice()
        let storage = try CredentialIsolation.scopedStorage()
        #expect(TraktTokenStore.clearForUserDisconnect())
        storage.isLocked = true

        let result = await CloudSyncEngine(container: container, shadow: shadow).reconcile()

        #expect(result.traktPending == 1)
        #expect(result.parentalPending == 1)
        #expect(result.credentialDeletionsPushed.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedTraktAccount>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedParentalPIN>()).count == 1)
        #expect(CredentialLinkStateStore.state(for: .trakt) == .disconnectedByUser(pendingPush: true))
    }

    @Test func `a failed keychain delete does not leave a disconnect pending`() throws {
        #expect(TraktTokenStore.save(makeTokens("kept")))
        try CredentialIsolation.scopedStorage().isLocked = true
        #expect(!TraktTokenStore.clearForUserDisconnect())
        #expect(CredentialLinkStateStore.state(for: .trakt) == .connected)
    }
}

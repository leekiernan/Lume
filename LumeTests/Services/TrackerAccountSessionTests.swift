//
//  TrackerAccountSessionTests.swift
//  LumeTests
//
//  The shared Trakt/Simkl sign-in lifecycle, driven through a scripted
//  backend: no network, keychain or defaults.
//

import Foundation
@testable import Lume
import Testing

// MARK: - Fake backend

private struct FakeCode: TrackerDeviceCode {
    var deviceCode = "device"
    var expiresIn = 600
    var interval = 1
}

private struct FakeTokens: TrackerTokens {
    var accessToken: String
    var refreshToken: String
    var issuedAt: TimeInterval
    var needsRefresh = false
}

private struct FakeIdentity: TrackerAccountIdentity {
    var username: String
    var scope: String
}

/// Scripted API and in-memory storage, shared by reference so tests can
/// inspect what the session did.
@MainActor
private final class FakeTracker {
    var storedTokens: FakeTokens?
    var storedIdentity: FakeIdentity?
    /// Identities `fetchIdentity` returns in turn; nil entries fail.
    var identityResponses: [FakeIdentity?] = []
    var pollResponses: [TrackerPollOutcome<FakeTokens>] = []
    var refreshResponse: TrackerRefreshOutcome<FakeTokens> = .unavailable
    var refreshCalls = 0
    var revoked: [String] = []
    var credentialChanges = 0
    var disconnectRecorded = false
}

@MainActor
private struct FakeBackend: TrackerAccountBackend {
    static let name = "Fake"
    static let slowDownStep: TimeInterval = 1
    let tracker: FakeTracker

    var isConfigured: Bool {
        true
    }

    func requestDeviceCode() async throws -> FakeCode {
        FakeCode()
    }

    func poll(_: FakeCode) async -> TrackerPollOutcome<FakeTokens> {
        tracker.pollResponses.isEmpty ? .pending : tracker.pollResponses.removeFirst()
    }

    func refresh(_: String) async -> TrackerRefreshOutcome<FakeTokens> {
        tracker.refreshCalls += 1
        return tracker.refreshResponse
    }

    func revoke(accessToken: String) async {
        tracker.revoked.append(accessToken)
    }

    func fetchIdentity(accessToken _: String) async -> FakeIdentity? {
        tracker.identityResponses.isEmpty ? nil : tracker.identityResponses.removeFirst()
    }

    func loadTokens() -> FakeTokens? {
        tracker.storedTokens
    }

    func saveTokens(_ tokens: FakeTokens) -> Bool {
        tracker.storedTokens = tokens
        return true
    }

    func clearTokensForUserDisconnect() -> Bool {
        tracker.disconnectRecorded = true
        tracker.storedTokens = nil
        return true
    }

    func credentialsDidChange() {
        tracker.credentialChanges += 1
    }

    func loadIdentity() -> FakeIdentity? {
        tracker.storedIdentity
    }

    func saveIdentity(_ identity: FakeIdentity) {
        tracker.storedIdentity = identity
    }

    func clearIdentity() {
        tracker.storedIdentity = nil
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 200 where !condition() {
        try await Task.sleep(for: .milliseconds(20))
    }
}

private let alice = FakeIdentity(username: "alice", scope: "fake:1")

// MARK: - Session

@MainActor
struct TrackerAccountSessionTests {
    private func makeSession(_ tracker: FakeTracker) -> TrackerAccountSession<FakeBackend> {
        TrackerAccountSession(backend: FakeBackend(tracker: tracker), identityRetryDelay: .milliseconds(20))
    }

    @Test func `restoring with no tokens is signed out and forgets the identity`() async {
        let tracker = FakeTracker()
        tracker.storedIdentity = alice
        let session = makeSession(tracker)

        #expect(await session.restore() == .signedOut)
        #expect(!session.isConnected)
        #expect(tracker.storedIdentity == nil)
    }

    @Test func `restoring keeps the remembered account while offline`() async {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "a", refreshToken: "r", issuedAt: 1)
        tracker.storedIdentity = alice
        let session = makeSession(tracker)

        #expect(await session.restore() == .ready)
        #expect(session.isConnected)
        #expect(session.username == "alice")
    }

    /// The reinstall case: tokens came back from iCloud, the remembered name
    /// didn't, and the first lookup fails. Still connected, and the name
    /// arrives on a later attempt rather than Settings offering Connect.
    @Test func `tokens without a known account stay connected and resolve it later`() async throws {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "a", refreshToken: "r", issuedAt: 1)
        tracker.identityResponses = [nil, nil, alice]
        let session = makeSession(tracker)

        _ = await session.restore()
        #expect(session.isConnected)
        #expect(session.username == nil)

        try await waitUntil { session.username != nil }
        #expect(session.username == "alice")
        #expect(tracker.storedIdentity == alice)
    }

    @Test func `a rejected refresh token is not retried until a new pair arrives`() async {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "a", refreshToken: "r", issuedAt: 1, needsRefresh: true)
        tracker.storedIdentity = alice
        tracker.refreshResponse = .rejected
        let session = makeSession(tracker)

        #expect(await session.restore() == .waiting)
        #expect(await session.validAccessToken() == nil)
        #expect(tracker.refreshCalls == 1)
        // Still connected: another device may be rotating the shared token.
        #expect(session.isConnected)
    }

    @Test func `identity changes say whether queued work can go out`() async {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "a", refreshToken: "r", issuedAt: 1)
        tracker.storedIdentity = alice
        tracker.identityResponses = [alice]
        let session = makeSession(tracker)
        var changes: [Bool] = []
        session.identityDidChange = { _, confirmed in changes.append(confirmed) }

        _ = await session.restore()

        // Remembered first (queue for it), then confirmed with a working token.
        #expect(changes == [false, true])
    }

    @Test func `the device flow connects and resolves the account`() async throws {
        let tracker = FakeTracker()
        tracker.pollResponses = [.approved(FakeTokens(accessToken: "new", refreshToken: "r", issuedAt: 2))]
        tracker.identityResponses = [alice]
        let session = makeSession(tracker)
        var connected = false
        session.didConnect = { connected = true }

        session.connect()
        #expect(session.isConnecting)
        try await waitUntil { connected }

        #expect(session.username == "alice")
        #expect(tracker.storedTokens?.accessToken == "new")
        #expect(tracker.credentialChanges == 1)
    }

    @Test func `a failed device flow shows why and allows another attempt`() async throws {
        let tracker = FakeTracker()
        tracker.pollResponses = [.failed(.declined)]
        let session = makeSession(tracker)

        session.connect()
        try await waitUntil { session.connectionError != nil }
        #expect(session.connectionError == "Authorization was declined.")
        #expect(!session.isConnecting)

        session.connect()
        #expect(session.isConnecting)
        #expect(session.connectionError == nil)
        session.cancelConnect()
    }

    @Test func `disconnect revokes, records the decision and signs out`() async {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "a", refreshToken: "r", issuedAt: 1)
        tracker.storedIdentity = alice
        let session = makeSession(tracker)
        _ = await session.restore()

        await session.disconnect()

        #expect(tracker.revoked == ["a"])
        #expect(tracker.disconnectRecorded)
        #expect(tracker.credentialChanges == 1)
        #expect(tracker.storedIdentity == nil)
        #expect(!session.isConnected)
        #expect(session.identity == nil)
    }
}

// MARK: - Machine

@MainActor
struct TrackerSessionMachineTests {
    private typealias Machine = TrackerSessionMachine<FakeCode>

    @Test func `connect, code, approval`() {
        var machine = Machine()
        #expect(machine.handle(.connectRequested) == [.startDeviceFlow])
        #expect(machine.handle(.codeIssued(FakeCode())) == [])
        #expect(machine.pendingCode == FakeCode())
        #expect(machine.handle(.tokensHeld(account: "alice")) == [.cancelDeviceFlow])
        #expect(machine.state == .connected(account: "alice"))
    }

    @Test func `a late code after a cancel is ignored`() {
        var machine = Machine()
        _ = machine.handle(.connectRequested)
        #expect(machine.handle(.connectCancelled) == [.cancelDeviceFlow])
        #expect(machine.handle(.codeIssued(FakeCode())) == nil)
        #expect(machine.state == .signedOut)
    }

    @Test func `unknown account asks for the identity, and a known name is kept`() {
        var machine = Machine()
        #expect(machine.handle(.tokensHeld(account: nil)) == [.resolveIdentity])
        #expect(machine.state == .connected(account: nil))
        _ = machine.handle(.identityResolved(account: "alice"))
        // A later restore without a remembered name doesn't forget it.
        #expect(machine.handle(.tokensHeld(account: nil)) == [])
        #expect(machine.account == "alice")
    }

    @Test func `a removal elsewhere doesn't interrupt signing in here`() {
        var machine = Machine()
        _ = machine.handle(.connectRequested)
        #expect(machine.handle(.tokensGone) == nil)
        #expect(machine.isConnecting)
    }

    @Test func `a name resolved after disconnecting is ignored`() {
        var machine = Machine()
        _ = machine.handle(.tokensHeld(account: nil))
        _ = machine.handle(.disconnected)
        #expect(machine.handle(.identityResolved(account: "alice")) == nil)
        #expect(machine.state == .signedOut)
    }
}

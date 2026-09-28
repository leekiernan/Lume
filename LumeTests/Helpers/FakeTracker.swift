//
//  FakeTracker.swift
//  LumeTests
//
//  A scripted tracker backend for the shared Trakt/Simkl session and queue:
//  no network, keychain or defaults.
//

import Foundation
@testable import Lume

struct FakeCode: TrackerDeviceCode {
    var deviceCode = "device"
    var expiresIn = 600
    var interval = 1
}

struct FakeTokens: TrackerTokens {
    var accessToken: String
    var refreshToken: String
    var issuedAt: TimeInterval
    var needsRefresh = false
}

struct FakeIdentity: TrackerAccountIdentity {
    var username: String
    var scope: String
    var previous: [String] = []

    var previousScopes: [String] {
        previous
    }
}

/// Scripted API and in-memory storage, shared by reference so tests can
/// inspect what the session did.
@MainActor
final class FakeTracker {
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
    /// How each delivery goes, in turn; `.sent` once the list runs out.
    var deliveryResponses: [FakeDelivery] = []
    /// Every mutation the queue tried to send, in order.
    var deliveryAttempts: [TrackerMutation.Target] = []
}

enum FakeDelivery {
    case sent
    case unsupported
    case failed
}

struct FakeDeliveryError: Error {}

@MainActor
struct FakeBackend: TrackerAccountBackend {
    static let name = "Fake"
    static let slowDownStep: TimeInterval = 1
    static let outboxStorageKey = "fake.mutationOutbox"
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

    func deliver(_ mutation: TrackerMutation, accessToken _: String) async throws -> Bool {
        tracker.deliveryAttempts.append(mutation.target)
        let outcome = tracker.deliveryResponses.isEmpty ? .sent : tracker.deliveryResponses.removeFirst()
        switch outcome {
        case .sent: return true
        case .unsupported: return false
        case .failed: throw FakeDeliveryError()
        }
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

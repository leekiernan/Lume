//
//  TrackerAccountBackend.swift
//  Lume
//
//  What a watch-history tracker (Trakt, Simkl) has to supply for the shared
//  `TrackerAccountSession` to sign it in and keep it signed in: its device-flow
//  and token endpoints with their errors mapped to shared outcomes, and where
//  its tokens and account identity are stored. Everything else about the
//  lifecycle is the session's, written once.
//

import Foundation

/// An OAuth device code as the device flow needs it.
nonisolated protocol TrackerDeviceCode: Equatable {
    var deviceCode: String { get }
    var expiresIn: Int { get }
    var interval: Int { get }
}

/// A stored token pair.
nonisolated protocol TrackerTokens: Equatable {
    var accessToken: String { get }
    var refreshToken: String { get }
    /// When the pair was issued. Orders pairs from different devices: an older
    /// in-flight refresh must never overwrite a newer pair from iCloud.
    var issuedAt: TimeInterval { get }
    var needsRefresh: Bool { get }
}

/// Who the tokens belong to.
nonisolated protocol TrackerAccountIdentity: Equatable {
    var username: String { get }
    /// Stable partition for the account's durable mutations.
    var scope: String { get }
}

/// One device-flow poll.
enum TrackerPollOutcome<Tokens> {
    case pending
    case slowDown
    case approved(Tokens)
    case failed(TrackerConnectFailure)
}

/// One refresh attempt.
enum TrackerRefreshOutcome<Tokens> {
    case refreshed(Tokens)
    /// The service refused this refresh token. Single-use tokens make that
    /// common when another device refreshed first, so the session waits for
    /// iCloud to deliver the new pair rather than retrying the dead one.
    case rejected
    /// Transport or server trouble; worth retrying on the next request.
    case unavailable
}

@MainActor
protocol TrackerAccountBackend {
    associatedtype Code: TrackerDeviceCode
    associatedtype Tokens: TrackerTokens
    associatedtype Identity: TrackerAccountIdentity

    /// The service's name, as shown in messages and logs.
    static var name: String { get }
    /// Seconds added to the poll interval on a slow-down reply.
    static var slowDownStep: TimeInterval { get }

    var isConfigured: Bool { get }

    func requestDeviceCode() async throws -> Code
    func poll(_ code: Code) async -> TrackerPollOutcome<Tokens>
    func refresh(_ refreshToken: String) async -> TrackerRefreshOutcome<Tokens>
    func revoke(accessToken: String) async
    func fetchIdentity(accessToken: String) async -> Identity?

    func loadTokens() -> Tokens?
    /// Returns whether storage changed.
    func saveTokens(_ tokens: Tokens) -> Bool
    /// Records the user's decision before deleting, so iCloud propagates it.
    /// Returns whether storage changed.
    func clearTokensForUserDisconnect() -> Bool
    /// Tells iCloud sync about a local credential change.
    func credentialsDidChange()

    func loadIdentity() -> Identity?
    func saveIdentity(_ identity: Identity)
    func clearIdentity()
}

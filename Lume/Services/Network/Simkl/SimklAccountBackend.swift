//
//  SimklAccountBackend.swift
//  Lume
//
//  Simkl's side of the shared tracker sign-in (`TrackerAccountSession`): its
//  device-flow and token endpoints, with Simkl's errors mapped to the shared
//  outcomes, and where its tokens and account identity live.
//

import Foundation

extension SimklDeviceCode: TrackerDeviceCode {}
extension SimklTokens: TrackerTokens {}
extension SimklAccountIdentity: TrackerAccountIdentity {
    var previousScopes: [String] {
        [legacyScope]
    }
}

struct SimklAccountBackend: TrackerAccountBackend {
    static let name = "Simkl"
    /// Simkl asks for a flat +5 s on slow-down.
    static let slowDownStep: TimeInterval = 5
    static let outboxStorageKey = "simkl.mutationOutbox.v1"

    private let client: SimklClient

    init(client: SimklClient = .shared) {
        self.client = client
    }

    var isConfigured: Bool {
        client.isConfigured
    }

    func requestDeviceCode() async throws -> SimklDeviceCode {
        try await client.requestDeviceCode()
    }

    func poll(_ code: SimklDeviceCode) async -> TrackerPollOutcome<SimklTokens> {
        do {
            return try await .approved(client.pollForToken(deviceCode: code.deviceCode).tokens)
        } catch SimklError.authorizationPending {
            return .pending
        } catch SimklError.slowDown {
            return .slowDown
        } catch SimklError.codeExpired {
            return .failed(.codeExpired)
        } catch SimklError.invalidClient {
            return .failed(.rejectedApp)
        } catch {
            return .failed(.unreachable)
        }
    }

    /// Simkl's refresh token doesn't rotate, so a rejection means it was
    /// revoked or expired rather than consumed by another device. The session
    /// still keeps the pair instead of erasing it: clearing would sync the
    /// disconnect to every device, and a re-authorized pair may still arrive
    /// through iCloud.
    func refresh(_ refreshToken: String) async -> TrackerRefreshOutcome<SimklTokens> {
        do {
            return try await .refreshed(client.refreshToken(refreshToken).tokens)
        } catch SimklError.server(400) {
            // A rejected refresh token comes back as an OAuth error envelope
            // at 400; `postOAuth` never throws notAuthenticated.
            return .rejected
        } catch {
            return .unavailable
        }
    }

    func revoke(accessToken: String) async {
        try? await client.revokeToken(accessToken)
    }

    func fetchIdentity(accessToken: String) async -> SimklAccountIdentity? {
        guard let settings = try? await client.userSettings(accessToken: accessToken) else { return nil }
        return SimklAccountIdentity(settings: settings)
    }

    /// History only: the shared queue can carry Trakt's watchlist kinds and a
    /// show-level target, which Simkl history has no request for.
    func deliver(_ mutation: TrackerMutation, accessToken: String) async throws -> Bool {
        guard mutation.kind == .history else { return false }
        let items: SimklSyncItems? = switch mutation.target {
        case let .movie(tmdbID):
            SimklSyncItems.movie(tmdbID: tmdbID, title: nil)
        case let .episode(showTMDBID, season, episode):
            SimklSyncItems.episode(showTMDBID: showTMDBID, showTitle: nil, season: season, episode: episode)
        case .show:
            nil
        }
        guard let items else { return false }
        if mutation.isPresent {
            try await client.addToHistory(items, accessToken: accessToken)
        } else {
            try await client.removeFromHistory(items, accessToken: accessToken)
        }
        return true
    }

    func loadTokens() -> SimklTokens? {
        SimklTokenStore.load()
    }

    func saveTokens(_ tokens: SimklTokens) -> Bool {
        SimklTokenStore.save(tokens)
    }

    func clearTokensForUserDisconnect() -> Bool {
        SimklTokenStore.clearForUserDisconnect()
    }

    func credentialsDidChange() {
        NotificationCenter.default.post(name: .lumeSimklCredentialsDidChange, object: nil)
    }

    func loadIdentity() -> SimklAccountIdentity? {
        SimklAccountIdentityStore.load()
    }

    func saveIdentity(_ identity: SimklAccountIdentity) {
        SimklAccountIdentityStore.save(identity)
    }

    func clearIdentity() {
        SimklAccountIdentityStore.clear()
    }
}

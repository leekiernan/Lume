//
//  TraktAccountBackend.swift
//  Lume
//
//  Trakt's side of the shared tracker sign-in (`TrackerAccountSession`): its
//  device-flow and token endpoints, with Trakt's errors mapped to the shared
//  outcomes, and where its tokens and account identity live.
//

import Foundation

extension TraktDeviceCode: TrackerDeviceCode {}

extension TraktTokens: TrackerTokens {
    var issuedAt: TimeInterval {
        createdAt
    }
}

extension TraktAccountIdentity: TrackerAccountIdentity {
    /// Scoped by the stable numeric Trakt id where the profile carries one,
    /// else the normalized username.
    init(user: TraktUser) {
        let scope: String
        if let traktID = user.ids?.trakt {
            scope = "trakt:\(traktID)"
        } else {
            let normalized = user.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            scope = "username:\(normalized)"
        }
        self.init(username: user.username, scope: scope)
    }
}

struct TraktAccountBackend: TrackerAccountBackend {
    static let name = "Trakt"
    static let slowDownStep: TimeInterval = 1

    private let client = TraktClient.shared

    var isConfigured: Bool {
        client.isConfigured
    }

    func requestDeviceCode() async throws -> TraktDeviceCode {
        try await client.requestDeviceCode()
    }

    func poll(_ code: TraktDeviceCode) async -> TrackerPollOutcome<TraktTokens> {
        do {
            return try await .approved(client.pollForToken(deviceCode: code.deviceCode).tokens)
        } catch TraktError.authorizationPending {
            return .pending
        } catch TraktError.slowDown {
            return .slowDown
        } catch TraktError.codeExpired {
            return .failed(.codeExpired)
        } catch TraktError.codeDenied {
            return .failed(.declined)
        } catch TraktError.codeUsed {
            return .failed(.codeUsed)
        } catch {
            return .failed(.unreachable)
        }
    }

    func refresh(_ refreshToken: String) async -> TrackerRefreshOutcome<TraktTokens> {
        do {
            return try await .refreshed(client.refreshToken(refreshToken).tokens)
        } catch TraktError.server(400), TraktError.notAuthenticated {
            // Trakt actually refused the token; anything else is transient.
            return .rejected
        } catch {
            return .unavailable
        }
    }

    func revoke(accessToken: String) async {
        try? await client.revokeToken(accessToken)
    }

    func fetchIdentity(accessToken: String) async -> TraktAccountIdentity? {
        guard let user = try? await client.currentUser(accessToken: accessToken) else { return nil }
        return TraktAccountIdentity(user: user)
    }

    func loadTokens() -> TraktTokens? {
        TraktTokenStore.load()
    }

    func saveTokens(_ tokens: TraktTokens) -> Bool {
        TraktTokenStore.save(tokens)
    }

    func clearTokensForUserDisconnect() -> Bool {
        TraktTokenStore.clearForUserDisconnect()
    }

    func credentialsDidChange() {
        NotificationCenter.default.post(name: .lumeTraktCredentialsDidChange, object: nil)
    }

    func loadIdentity() -> TraktAccountIdentity? {
        TraktAccountIdentityStore.load()
    }

    func saveIdentity(_ identity: TraktAccountIdentity) {
        TraktAccountIdentityStore.save(identity)
    }

    func clearIdentity() {
        TraktAccountIdentityStore.clear()
    }
}

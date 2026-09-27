//
//  TraktTokenStore.swift
//  Lume
//
//  Keychain-backed persistence for the Trakt OAuth token set. Tokens are
//  secrets, so they live in the keychain rather than UserDefaults — encrypted
//  at rest and excluded from plaintext backups.
//
//  The keychain work goes through `CredentialBackend` (the safe add-or-update
//  pattern), and the item uses `AfterFirstUnlock` accessibility so a refresh
//  can succeed even if it ever runs while the device is locked.
//

import Foundation

/// The OAuth token set returned by Trakt, plus the metadata needed to know when
/// the access token needs refreshing.
nonisolated struct TraktTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Unix timestamp (seconds) when the access token was issued — Trakt's
    /// `created_at`.
    var createdAt: TimeInterval
    /// Lifetime of the access token in seconds — Trakt's `expires_in`.
    var expiresIn: TimeInterval
    var scope: String?
    var tokenType: String?

    /// Absolute moment the access token expires.
    var expiryDate: Date {
        Date(timeIntervalSince1970: createdAt + expiresIn)
    }

    /// Whether the token has expired or is within a day of doing so. The API's
    /// current lifetime is short and supplied dynamically in `expiresIn`, so no
    /// fixed Trakt lifetime is assumed here.
    var needsRefresh: Bool {
        expiryDate.timeIntervalSinceNow < 60 * 60 * 24
    }
}

/// Reads and writes the Trakt token set in the keychain (through
/// `CredentialBackend`). Stateless and thread-safe — the storage serializes
/// access.
nonisolated enum TraktTokenStore {
    private static let item = CredentialItem(
        service: "bilipp.Lume.trakt",
        account: "oauth-tokens",
        accessibility: .afterFirstUnlock
    )

    /// A sync reconcile must distinguish a missing token from a keychain read
    /// that failed while the device was locked. Treating the latter as a user
    /// disconnect would delete the shared authorization from every device.
    enum StoredTokens: Equatable {
        case tokens(TraktTokens)
        case notSet
        case unavailable
    }

    static func storedTokens() -> StoredTokens {
        switch CredentialBackend.current.storage.read(item) {
        case .notFound:
            return .notSet
        case .unavailable:
            return .unavailable
        case let .found(data):
            guard let tokens = try? JSONDecoder().decode(TraktTokens.self, from: data) else { return .unavailable }
            return .tokens(tokens)
        }
    }

    /// Loads the stored token set, or nil if it is absent or temporarily
    /// unreadable. UI/network callers do not need to distinguish those cases;
    /// the CloudKit reconciler uses `storedTokens()` when the distinction matters.
    static func load() -> TraktTokens? {
        guard case let .tokens(tokens) = storedTokens() else { return nil }
        return tokens
    }

    /// Saves the token set, replacing any existing one — a sign-in, a refresh,
    /// or a pair pulled from another device. Any of those means the account is
    /// connected here again (`CredentialLinkState`).
    @discardableResult
    static func save(_ tokens: TraktTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens),
              CredentialBackend.current.storage.write(data, to: item)
        else { return false }
        CredentialLinkStateStore.apply(.credentialStored, to: .trakt)
        return true
    }

    /// Removes the stored token set. A missing item is treated as success — the
    /// desired end state (no token) is already met.
    ///
    /// Not a user decision on its own: the sync reconcile calls this to apply
    /// another device's disconnect. The Disconnect button goes through
    /// `clearForUserDisconnect()`.
    @discardableResult
    static func clear() -> Bool {
        CredentialBackend.current.storage.delete(item)
    }

    /// The user's explicit Disconnect: records the decision before the token
    /// goes, so the iCloud reconcile propagates the removal to every device
    /// rather than restoring the token as if the keychain had merely lost it.
    @discardableResult
    static func clearForUserDisconnect() -> Bool {
        CredentialLinkStateStore.apply(.userDisconnected, to: .trakt)
        guard clear() else {
            CredentialLinkStateStore.apply(.removalFailed, to: .trakt)
            return false
        }
        return true
    }
}

//
//  SimklTokenStore.swift
//  Lume
//
//  Keychain-backed persistence for the Simkl OAuth token set. Tokens are
//  secrets, so they live in the keychain rather than UserDefaults — encrypted
//  at rest and excluded from plaintext backups.
//
//  Uses the SecItem API directly (the safe add-or-update pattern) rather than a
//  wrapper, and stores items with `AfterFirstUnlock` accessibility so a refresh
//  can succeed even if it ever runs while the device is locked.
//
//  Mirrors `TraktTokenStore`: SecItem directly with the safe update-then-add
//  pattern, `AfterFirstUnlock` accessibility, and `kSecUseDataProtectionKeychain`
//  to keep macOS aligned with iOS/tvOS behaviour.
//

import Foundation
import Security

/// The OAuth token set returned by Simkl's `/oauth2/token`, plus the metadata
/// needed to know when the access token needs refreshing.
nonisolated struct SimklTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Unix timestamp (seconds) when the access token was issued — captured
    /// client-side, as Simkl's token response carries no `created_at`.
    var issuedAt: TimeInterval
    /// Lifetime of the access token in seconds — Simkl's `expires_in` (7 days).
    var expiresIn: TimeInterval
    var scope: String?
    var tokenType: String?

    /// Absolute moment the access token expires.
    var expiryDate: Date {
        Date(timeIntervalSince1970: issuedAt + expiresIn)
    }

    /// Whether the token has expired or is within a day of doing so. Simkl
    /// access tokens last a week, so refreshing a day early is cheap insurance.
    var needsRefresh: Bool {
        expiryDate.timeIntervalSinceNow < 60 * 60 * 24
    }
}

/// Reads and writes the Simkl token set in the keychain. Stateless and
/// thread-safe — the keychain itself serializes access.
nonisolated enum SimklTokenStore {
    private static let service = "bilipp.Lume.simkl"
    private static let account = "oauth-tokens"

    /// Base query identifying the single token item by its primary key
    /// (service + account). `kSecUseDataProtectionKeychain` keeps macOS aligned
    /// with iOS/tvOS behaviour.
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// A sync reconcile must distinguish a missing token from a keychain read
    /// that failed while the device was locked. Treating the latter as a user
    /// disconnect would delete the shared authorization from every device.
    enum StoredTokens: Equatable {
        case tokens(SimklTokens)
        case notSet
        case unavailable
    }

    static func storedTokens() -> StoredTokens {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notSet }
        guard status == errSecSuccess,
              let data = result as? Data,
              let tokens = try? JSONDecoder().decode(SimklTokens.self, from: data)
        else { return .unavailable }
        return .tokens(tokens)
    }

    /// Loads the stored token set, or nil if it is absent or temporarily
    /// unreadable. UI/network callers do not need that distinction; the
    /// CloudKit reconciler uses `storedTokens()` when it matters.
    static func load() -> SimklTokens? {
        guard case let .tokens(tokens) = storedTokens() else { return nil }
        return tokens
    }

    /// Saves the token set, replacing any existing one. Uses update-then-add so
    /// item metadata survives and there's no delete/add race.
    @discardableResult
    static func save(_ tokens: SimklTokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// Removes the stored token set. A missing item is treated as success — the
    /// desired end state (no token) is already met.
    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Account identity

nonisolated struct SimklAccountIdentity: Codable, Equatable {
    let username: String
    /// The outbox partition for this account: the stable Simkl account id
    /// where the settings response carries one, else the normalized username.
    let scope: String

    init(username: String, scope: String) {
        self.username = username
        self.scope = scope
    }

    init(settings: SimklUserSettings) {
        username = settings.user.name
        if let id = settings.account?.id {
            scope = "simkl:\(id)"
        } else {
            scope = "username:\(Self.normalized(settings.user.name))"
        }
    }

    /// The partition the outbox used before identities were persisted — the
    /// bare normalized username. Changes queued under it are adopted into
    /// `scope` so an upgrade doesn't strand them.
    var legacyScope: String {
        Self.normalized(username)
    }

    private static func normalized(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The account identity is not secret. Remembering it alongside the keychain
/// token lets an offline cold launch stay connected and keep queueing watched
/// changes; the next successful `/users/settings` response refreshes it.
/// Mirrors `TraktAccountIdentityStore`.
nonisolated enum SimklAccountIdentityStore {
    private static let key = "simkl.lastAccountIdentity.v1"

    static func load(defaults: UserDefaults = .standard) -> SimklAccountIdentity? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SimklAccountIdentity.self, from: data)
    }

    static func save(_ identity: SimklAccountIdentity, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

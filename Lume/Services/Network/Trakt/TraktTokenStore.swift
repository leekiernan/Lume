//
//  TraktTokenStore.swift
//  Lume
//
//  Keychain-backed persistence for the Trakt OAuth token set. Tokens are
//  secrets, so they live in the keychain rather than UserDefaults — encrypted
//  at rest and excluded from plaintext backups.
//
//  Uses the SecItem API directly (the safe add-or-update pattern) rather than a
//  wrapper, and stores items with `AfterFirstUnlock` accessibility so a refresh
//  can succeed even if it ever runs while the device is locked.
//

import Foundation
import Security

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

/// Reads and writes the Trakt token set in the keychain. Stateless and
/// thread-safe — the keychain itself serializes access.
nonisolated enum TraktTokenStore {
    private static let service = "bilipp.Lume.trakt"
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
        case tokens(TraktTokens)
        case notSet
        case unavailable
    }

    static func storedTokens() -> StoredTokens {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .notSet
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let tokens = try? JSONDecoder().decode(TraktTokens.self, from: data)
        else { return .unavailable }
        return .tokens(tokens)
    }

    /// Loads the stored token set, or nil if it is absent or temporarily
    /// unreadable. UI/network callers do not need to distinguish those cases;
    /// the CloudKit reconciler uses `storedTokens()` when the distinction matters.
    static func load() -> TraktTokens? {
        guard case let .tokens(tokens) = storedTokens() else { return nil }
        return tokens
    }

    /// Saves the token set, replacing any existing one. Uses update-then-add so
    /// item metadata survives and there's no delete/add race.
    @discardableResult
    static func save(_ tokens: TraktTokens) -> Bool {
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

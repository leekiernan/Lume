//
//  CredentialStorage.swift
//  Lume
//
//  The one seam between Lume's credential stores and the keychain.
//
//  `TraktTokenStore`, `SimklTokenStore`, `ParentalControlsStore` and
//  `OpenSubtitlesSessionStore` each keep a single secret in the keychain. They
//  used to call `SecItem*` directly, which left no way to exercise them — or
//  anything that reads them, like the iCloud credential reconcile — without
//  touching the real items of whoever ran the code. The unit tests run hosted
//  inside the real app, so a test that cleared "the Trakt token" cleared the
//  developer's actual sign-in, and the next reconcile carried that loss to every
//  device.
//
//  So the stores now describe *which* item they want (`CredentialItem`) and hand
//  the SecItem work to a `CredentialStorage`. Production resolves to
//  `KeychainCredentialStorage`, which issues exactly the queries the stores used
//  to build themselves — same service/account strings, same accessibility, same
//  update-then-add write — so nothing already in a user's keychain moves.
//
//  `CredentialBackend` pairs that storage with the `UserDefaults` holding the
//  stores' small, non-secret device-local bookkeeping (the parental PIN presence
//  cache, `CredentialLinkState`), so a replaced backend replaces both together.
//

import Foundation
import os
import Security

/// One keychain item: a generic password identified by service + account.
nonisolated struct CredentialItem: Hashable {
    enum Accessibility: Hashable {
        /// Readable once the device has been unlocked after boot — the OAuth
        /// tokens, so a background refresh works on a locked device.
        case afterFirstUnlock
        /// Readable only while unlocked — the parental PIN hash.
        case whenUnlocked
    }

    let service: String
    let account: String
    let accessibility: Accessibility
}

/// The outcome of reading an item. `unavailable` must never be collapsed into
/// `notFound`: it is the keychain refusing to look (a locked device), which says
/// nothing about whether the item exists.
nonisolated enum CredentialRead: Equatable {
    case found(Data)
    case notFound
    case unavailable
}

/// Reads, writes and deletes credential items. Implementations must be safe to
/// call from any thread — the stores are `nonisolated` and the iCloud reconcile
/// reads them from the `CloudSyncEngine` actor.
nonisolated protocol CredentialStorage: Sendable {
    func read(_ item: CredentialItem) -> CredentialRead
    /// A presence check that never returns the item's data. nil when the store
    /// can't be read (the item's accessibility excludes the current lock state).
    func contains(_ item: CredentialItem) -> Bool?
    /// Stores `data`, replacing any existing value. False when the write was
    /// refused.
    func write(_ data: Data, to item: CredentialItem) -> Bool
    /// Removes the item. A missing item counts as success — the desired end
    /// state is already met.
    func delete(_ item: CredentialItem) -> Bool
}

/// The production storage: the data-protection keychain, via the SecItem API
/// directly. The safe update-then-add write keeps item metadata and avoids a
/// delete/add race; `kSecUseDataProtectionKeychain` keeps macOS aligned with
/// iOS/tvOS behaviour.
nonisolated struct KeychainCredentialStorage: CredentialStorage {
    func read(_ item: CredentialItem) -> CredentialRead {
        var query = Self.baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let data = result as? Data else { return .unavailable }
        return .found(data)
    }

    func contains(_ item: CredentialItem) -> Bool? {
        var query = Self.baseQuery(item)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    func write(_ data: Data, to item: CredentialItem) -> Bool {
        let accessible = Self.accessible(item.accessibility)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        let query = Self.baseQuery(item)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessible
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func delete(_ item: CredentialItem) -> Bool {
        let status = SecItemDelete(Self.baseQuery(item) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// The item's primary key (service + account).
    private static func baseQuery(_ item: CredentialItem) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func accessible(_ accessibility: CredentialItem.Accessibility) -> CFString {
        switch accessibility {
        case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
        case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
        }
    }
}

/// Where the credential stores keep their secrets and their device-local
/// bookkeeping.
///
/// Resolution order: a backend bound to the current task (`scoped`), else the
/// process-wide one (`install`), which starts out as the real keychain and
/// `UserDefaults.standard`. Production never replaces either; the seam exists so
/// a host — the unit-test bundle — can point every store at storage of its own
/// before any of its code runs.
nonisolated struct CredentialBackend {
    let storage: any CredentialStorage
    private let makeDefaults: @Sendable () -> UserDefaults

    /// The defaults holding non-secret, device-local credential bookkeeping.
    var defaults: UserDefaults {
        makeDefaults()
    }

    /// - Parameter defaults: resolved on each use rather than captured, so a
    ///   backend can be installed before its defaults suite may safely be
    ///   created.
    init(storage: any CredentialStorage, defaults: @escaping @Sendable () -> UserDefaults) {
        self.storage = storage
        makeDefaults = defaults
    }

    /// The real keychain and standard defaults.
    static let system = CredentialBackend(storage: KeychainCredentialStorage(), defaults: { .standard })

    /// Overrides the backend for the current task and everything it awaits.
    @TaskLocal static var scoped: CredentialBackend?

    private static let installed = OSAllocatedUnfairLock<CredentialBackend>(initialState: .system)

    /// The backend every credential store reads and writes.
    static var current: CredentialBackend {
        scoped ?? installed.withLock { $0 }
    }

    /// Replaces the process-wide backend.
    static func install(_ backend: CredentialBackend) {
        installed.withLock { $0 = backend }
    }
}

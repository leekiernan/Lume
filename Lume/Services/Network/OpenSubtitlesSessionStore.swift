//
//  OpenSubtitlesSessionStore.swift
//  Lume
//
//  Keychain-backed persistence for the OpenSubtitles user session. The token is
//  a credential, so it lives in the keychain rather than UserDefaults —
//  encrypted at rest and excluded from plaintext backups. Mirrors
//  `TraktTokenStore`: the keychain work goes through `CredentialBackend`, with
//  `AfterFirstUnlock` accessibility.
//

import Foundation

/// Reads and writes the OpenSubtitles session in the keychain (through
/// `CredentialBackend`). Stateless and thread-safe — the storage serializes
/// access.
enum OpenSubtitlesSessionStore {
    private static let item = CredentialItem(
        service: "bilipp.Lume.opensubtitles",
        account: "user-session",
        accessibility: .afterFirstUnlock
    )

    /// The stored session, or nil when the user has never signed in (or signed
    /// out). Any decode/keychain miss reads as "no session" rather than throwing.
    static func load() -> OpenSubtitlesSession? {
        guard case let .found(data) = CredentialBackend.current.storage.read(item) else { return nil }
        return try? JSONDecoder().decode(OpenSubtitlesSession.self, from: data)
    }

    /// Saves the session, replacing any existing one. Update-then-add so item
    /// metadata survives and there's no delete/add race.
    @discardableResult
    static func save(_ session: OpenSubtitlesSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        return CredentialBackend.current.storage.write(data, to: item)
    }

    /// Removes the stored session. A missing item counts as success — the
    /// desired end state (no session) is already met.
    @discardableResult
    static func clear() -> Bool {
        CredentialBackend.current.storage.delete(item)
    }
}

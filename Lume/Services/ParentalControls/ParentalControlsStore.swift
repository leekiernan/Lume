//
//  ParentalControlsStore.swift
//  Lume
//
//  Keychain-backed storage for the parental-control PIN. The PIN gates leaving a
//  child profile and editing Content Management; it isn't a high-value secret,
//  but it lives in the keychain (encrypted at rest, excluded from plaintext
//  backups) rather than UserDefaults — and only a salted SHA-256 hash is stored,
//  never the PIN itself, so a keychain dump can't reveal a PIN the user might
//  reuse elsewhere.
//
//  Mirrors `TraktTokenStore`: the keychain work goes through `CredentialBackend`
//  (the safe update-then-add pattern). `WhenUnlocked` accessibility keeps the
//  hash unreadable while the device is locked.
//
//  The keychain is the local store of record — `verify` reads it and nothing
//  else. It is *not* the transport between devices: iCloud Keychain never syncs
//  to tvOS, which is the one platform where an unenforced parental gate matters
//  most. `CloudSyncEngine+Parental` carries the hash between devices over the
//  CloudKit private database instead, using `storedHash` / `store(hash:)` below.
//
//  That reconcile can run while the device is *locked* (the pre-suspension flush
//  fires as the screen locks, and a CloudKit push can wake the process), and a
//  `WhenUnlocked` item is unreadable then. So every accessor below distinguishes
//  "no PIN" from "couldn't look": conflating the two makes the reconciler read a
//  locked keychain as "the parent removed the PIN" and push that deletion to
//  every other device.
//
//  `nonisolated` because that reconcile runs on the `CloudSyncEngine` actor, off
//  the main actor (the project defaults to main-actor isolation). Safe: this type
//  holds no state of its own — every call goes straight to the thread-safe
//  `CredentialStorage`.
//

import CryptoKit
import Foundation

nonisolated enum ParentalControlsStore {
    private static let item = CredentialItem(
        service: "bilipp.Lume.parental",
        account: "pin-hash",
        accessibility: .whenUnlocked
    )
    /// Mixed into the hash. Not a secret (it ships in the binary); it only stops
    /// the stored value from being a bare SHA-256 of a four-digit PIN.
    private static let salt = "lume.parental.v1"

    /// The result of reading the stored hash. `unavailable` is the case that must
    /// never be collapsed into `notSet`: the keychain refused the read (the
    /// device is locked), which says nothing about whether a PIN exists.
    enum StoredHash: Equatable {
        case hash(String)
        case notSet
        case unavailable
    }

    /// Remembers the last *conclusive* answer to "is a PIN set", so an
    /// inconclusive keychain read (device locked) doesn't read as "no PIN" and
    /// switch every gate in `ParentalControls` off — they are all guarded on
    /// `isPINSet`. Only presence is cached here; the hash never leaves the
    /// keychain.
    private static let presenceKey = "parental.pinPresent"

    /// Whether a PIN has been set. A presence check — never returns the hash.
    /// Falls back to the last conclusive answer when the keychain can't be read.
    static var isSet: Bool {
        let backend = CredentialBackend.current
        guard let present = backend.storage.contains(item) else {
            return backend.defaults.bool(forKey: presenceKey)
        }
        return cachePresence(present)
    }

    /// Stores the salted hash of `pin`, replacing any existing one.
    @discardableResult
    static func save(pin: String) -> Bool {
        store(hash: hash(pin))
    }

    /// The stored salted hash, or why it couldn't be read.
    ///
    /// Only the sync reconciler should need this — it is what gets mirrored to
    /// the other devices. UI code wants `isSet` or `verify` instead.
    static func storedHash() -> StoredHash {
        switch CredentialBackend.current.storage.read(item) {
        case .notFound:
            cachePresence(false)
            return .notSet
        case .unavailable:
            return .unavailable
        case let .found(data):
            guard let hash = String(data: data, encoding: .utf8) else { return .unavailable }
            cachePresence(true)
            return .hash(hash)
        }
    }

    /// Writes an already-hashed PIN. The counterpart to `storedHash` — used when
    /// pulling another device's PIN down from iCloud, where the PIN itself was
    /// never transmitted and so cannot be re-hashed.
    ///
    /// Returns false when the keychain refused the write (again: a locked
    /// device). The sync reconciler must not baseline a value the keychain never
    /// took — the next pass would read the missing hash as a local deletion and
    /// push it, wiping the PIN on every other device.
    @discardableResult
    static func store(hash: String) -> Bool {
        guard CredentialBackend.current.storage.write(Data(hash.utf8), to: item) else { return false }
        cachePresence(true)
        return true
    }

    /// Whether `pin` matches the stored PIN. False when no PIN is set.
    static func verify(pin: String) -> Bool {
        guard case let .found(data) = CredentialBackend.current.storage.read(item),
              let stored = String(data: data, encoding: .utf8)
        else { return false }
        return verify(pin: pin, against: stored)
    }

    /// Removes the stored PIN. A missing item is treated as success.
    @discardableResult
    static func clear() -> Bool {
        guard CredentialBackend.current.storage.delete(item) else { return false }
        cachePresence(false)
        return true
    }

    @discardableResult
    private static func cachePresence(_ present: Bool) -> Bool {
        CredentialBackend.current.defaults.set(present, forKey: presenceKey)
        return present
    }

    /// Produces the same one-way representation used by both the global
    /// parental PIN and profile-specific PINs.
    static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Verifies a PIN against an already-persisted hash without touching the
    /// keychain. Profile PIN hashes live on their CloudKit-synced profile row.
    static func verify(pin: String, against storedHash: String) -> Bool {
        !storedHash.isEmpty && storedHash == hash(pin)
    }
}

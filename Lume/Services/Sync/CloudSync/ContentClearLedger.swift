//
//  ContentClearLedger.swift
//  Lume
//
//  The titles whose user state the viewer cleared on this device since the
//  last sync — unwatched, unfavourited, taken out of Recently Watched, shown
//  again, reordered back. Without it a blank catalog row is ambiguous: the
//  viewer clearing it, or a playlist resync re-creating the row with nothing
//  on it. The sync reads a blank row as the viewer's clear only when it's
//  here (`ContentIntentMerge`), the same way `CredentialLinkState` records a
//  sign-out instead of inferring it from a missing token.
//
//  Device-local (UserDefaults), and short-lived: the sync removes what it has
//  pushed once both stores are saved. Recording more than a clear is harmless —
//  it's only read for a row that is blank.
//

import Foundation

final nonisolated class ContentClearLedger: @unchecked Sendable {
    static let shared = ContentClearLedger()
    /// Parental category restrictions the parent lifted — kept apart from
    /// `shared`, where a category id means it was shown again or reordered.
    static let restrictionLifts = ContentClearLedger(key: "cloudsync.restrictionLifts.v1")

    private let defaults: UserDefaults
    private let key: String
    /// The UI records and the sync removes, on different threads: every change
    /// is a read-modify-write of one key.
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "cloudsync.contentClears.v1") {
        self.defaults = defaults
        self.key = key
    }

    /// The viewer cleared state on these titles (catalog ids = content ids).
    func record(_ ids: some Sequence<String>) {
        lock.withLock {
            let next = stored().union(ids)
            defaults.set(Array(next), forKey: key)
        }
    }

    func record(_ id: String) {
        record(CollectionOfOne(id))
    }

    var ids: Set<String> {
        lock.withLock { stored() }
    }

    /// The sync pushed these; clears recorded since stay for the next pass.
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            let next = stored().subtracting(ids)
            if next.isEmpty {
                defaults.removeObject(forKey: key)
            } else {
                defaults.set(Array(next), forKey: key)
            }
        }
    }

    /// A profile switch: the catalog now projects another profile's state.
    /// (Not for restriction lifts: restrictions aren't per profile.)
    func reset() {
        lock.withLock { defaults.removeObject(forKey: key) }
    }

    private func stored() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}

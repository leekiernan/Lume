import Foundation

/// The id of the currently active profile, persisted in `UserDefaults`.
///
/// A small scalar flag (not structured data), so `UserDefaults` is appropriate —
/// and it must be reachable from the sync engine's background actor *without* a
/// SwiftData fetch, which is why it lives here rather than on a model. Written by
/// `ProfileManager`, read by `CloudSyncEngine` to scope content reconciliation.
nonisolated enum ActiveProfileStore {
    static let key = "profiles.activeProfileID.v1"

    static var current: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

/// The profile last chosen on any of the account's devices, which every device
/// starts on at its next launch (`ProfileManager.followLastActiveProfile`).
/// Synced through the account settings (`AccountSettingsSync`).
///
/// A key of its own rather than `ActiveProfileStore`'s: switching a profile
/// re-projects the catalog, so a value arriving from iCloud must never change
/// the active profile under a running device — it is only read at launch.
/// Written only when someone picks a profile, never by the launch bootstrap,
/// so a launch can't overwrite the choice it is about to follow.
nonisolated enum LastActiveProfile {
    static let key = "profiles.lastActiveProfileID.v1"

    static var id: UUID? {
        get { UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: key) }
    }
}

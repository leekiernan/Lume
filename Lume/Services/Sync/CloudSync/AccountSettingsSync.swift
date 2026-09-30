//
//  AccountSettingsSync.swift
//  Lume
//
//  Which app settings follow the account between devices, and how a device's
//  values meet iCloud's (`SyncedAccountSettings`). Pure, so the merge is
//  testable without a store; `CloudSyncEngine+AccountSettings` runs it.
//
//  Merged key by key, three ways against a shadow baseline, like every other
//  pass: changing the audio languages on the TV and autoplay on the phone keeps
//  both, and a key changed on both sides takes iCloud's value. A key never set
//  on a device is *unset*, not its default — so a fresh install adopts the
//  account's settings rather than publishing its defaults over them.
//

import Foundation

/// One setting's value, as `UserDefaults` holds it.
nonisolated enum SyncedSettingValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
}

/// Every synced setting that is set, by key.
nonisolated struct AccountSettingsValues: Codable, Equatable {
    var values: [String: SyncedSettingValue] = [:]

    subscript(key: String) -> SyncedSettingValue? {
        get { values[key] }
        set { values[key] = newValue }
    }
}

nonisolated enum AccountSettingsSync {
    enum Kind {
        case string
        case bool
    }

    /// The synced settings: the player and search *choices*. Engine tuning
    /// (buffers, hardware decode, deinterlacing) and the external player stay
    /// on each device on purpose. Remote swipes sync: a device without a Siri
    /// Remote simply never reads it.
    static let keys: [(key: String, kind: Kind)] = [
        (PlayerSettings.engineKey, .string),
        (PlayerSettings.enginePriorityKey, .string),
        (PlayerSettings.liveSurfModeKey, .string),
        (PlayerSettings.tvRemoteSwipesKey, .bool),
        (PlayerSettings.Playback.autoPlayNextKey, .bool),
        (PlayerSettings.Playback.showNextEpisodeButtonKey, .bool),
        (PlayerSettings.Playback.showSkipIntroButtonKey, .bool),
        (PlayerSettings.StreamInfo.enabledKey, .bool),
        (PlayerSettings.StreamInfo.detailLevelKey, .string),
        (PlayerSettings.Language.preferredAudioLanguagesKey, .string),
        (SearchSettings.searchAllPlaylistsKey, .bool)
    ]

    /// The synced settings this device has set.
    static func snapshot(from defaults: UserDefaults) -> AccountSettingsValues {
        var snapshot = AccountSettingsValues()
        for (key, kind) in keys where defaults.object(forKey: key) != nil {
            switch kind {
            case .string:
                if let value = defaults.string(forKey: key) { snapshot[key] = .string(value) }
            case .bool:
                snapshot[key] = .bool(defaults.bool(forKey: key))
            }
        }
        return snapshot
    }

    /// Writes merged values into `defaults`; nil unsets the key.
    static func apply(_ writes: [String: SyncedSettingValue?], to defaults: UserDefaults) {
        for (key, value) in writes {
            switch value {
            case let .string(string): defaults.set(string, forKey: key)
            case let .bool(bool): defaults.set(bool, forKey: key)
            case nil: defaults.removeObject(forKey: key)
            }
        }
    }

    /// What one pass does.
    struct Outcome: Equatable {
        /// The values to store in iCloud, when they differ from what is there.
        var cloudWrite: AccountSettingsValues?
        /// Settings to change on this device; nil unsets.
        var localWrites: [String: SyncedSettingValue?] = [:]
        /// The new agreed baseline.
        var shadow = AccountSettingsValues()
        var pushed = 0
        var pulled = 0
    }

    /// Merges each synced key three ways; conflicts take iCloud's value. Keys
    /// in iCloud that this build doesn't sync — a newer version's — ride
    /// through untouched.
    static func merge(
        local: AccountSettingsValues,
        cloud: AccountSettingsValues?,
        shadow: AccountSettingsValues?
    ) -> Outcome {
        var outcome = Outcome()
        var merged = cloud ?? AccountSettingsValues()
        for (key, _) in keys {
            let verdict = CloudSyncMerge.reconcile(
                local: local[key], cloud: cloud?[key], shadow: shadow?[key],
                mergeConflict: { _, cloud in cloud }
            )
            switch verdict {
            case .noChange:
                outcome.shadow[key] = shadow?[key]
            case let .pushToCloud(value):
                if merged[key] != value { outcome.pushed += 1 }
                merged[key] = value
                outcome.shadow[key] = value
            case let .pullToLocal(value):
                outcome.localWrites[key] = .some(value)
                outcome.pulled += 1
                outcome.shadow[key] = value
            case let .writeBoth(value):
                outcome.localWrites[key] = .some(value)
                outcome.pulled += 1
                merged[key] = value
                outcome.shadow[key] = value
            }
        }
        if merged != (cloud ?? AccountSettingsValues()) {
            outcome.cloudWrite = merged
        }
        return outcome
    }

    static func encode(_ values: AccountSettingsValues) -> String? {
        let encoder = JSONEncoder()
        // Stable bytes, so an unchanged value never reads as an edit.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(values) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> AccountSettingsValues? {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(AccountSettingsValues.self, from: data)
    }
}

//
//  ProfileScopedPreferences.swift
//  Lume
//
//  Layout preferences belong to a person, not a device: which areas appear,
//  which rows each carries, in what order, and the custom rows someone added.
//  Their live values stay in UserDefaults (they are small scalars — see
//  `HomeLayoutSettings`) so `@AppStorage` remains immediately reactive. A JSON
//  snapshot on the CloudKit-backed `UserProfile` mirrors those values between
//  devices; this type owns both the key scoping and snapshot conversion.
//
//  Everything else in UserDefaults stays device-wide on purpose — the selected
//  playlist, sync cadence and player engine preferences describe *this device's*
//  setup, not the viewer's taste.
//

import Foundation

nonisolated struct ProfilePreferencesSnapshot: Codable, Equatable {
    var strings: [String: String]
    var booleans: [String: Bool]
}

nonisolated enum ProfileScopedPreferences {
    /// Scopes a layout key to the active profile. Falls back to the bare key
    /// before a profile exists (first launch, previews, unit tests), which is
    /// also the value the migration below reads from.
    static func key(_ base: String) -> String {
        key(base, profileID: ActiveProfileStore.current)
    }

    /// Explicit-id form used while a switch is moving between two profiles.
    /// It must not rely on `ActiveProfileStore.current`, which the sync engine
    /// changes atomically with the catalog projection.
    static func key(_ base: String, profileID: UUID?) -> String {
        guard let id = profileID else { return base }
        return "profile.\(id.uuidString).\(base)"
    }

    /// Every layout key that is scoped, listed once so the migration can move
    /// all of them and none is forgotten when a new surface is added.
    static var scopedBaseKeys: [String] {
        var keys = [
            AppAreaSettings.baseDisabledAreasKey,
            RecommendationSettings.baseEnabledKey
        ]
        for surface in SectionSurface.allCases {
            keys.append(HomeLayoutSettings.baseSectionOrderKey(surface))
            keys.append(HomeLayoutSettings.baseDisabledSectionsKey(surface))
            keys.append(HomeLayoutSettings.baseHeroSectionKey(surface))
            keys.append(HomeLayoutSettings.baseHeroSeededKey(surface))
            keys.append(CustomHomeSections.baseStorageKey(surface))
        }
        return keys
    }

    private static var booleanBaseKeys: Set<String> {
        [RecommendationSettings.baseEnabledKey]
    }

    /// Captures every syncable value, including defaults. Explicit empty/false
    /// values are important: they represent a user re-enabling an area or row
    /// that another device still has disabled.
    static func snapshot(
        profileID: UUID,
        defaults: UserDefaults = .standard
    ) -> ProfilePreferencesSnapshot {
        var strings: [String: String] = [:]
        var booleans: [String: Bool] = [:]
        for base in scopedBaseKeys {
            let scoped = key(base, profileID: profileID)
            if booleanBaseKeys.contains(base) {
                booleans[base] = defaults.object(forKey: scoped) == nil
                    ? RecommendationSettings.enabledDefault
                    : defaults.bool(forKey: scoped)
            } else {
                strings[base] = defaults.string(forKey: scoped) ?? ""
            }
        }
        return ProfilePreferencesSnapshot(strings: strings, booleans: booleans)
    }

    /// Whether this install has any pre-snapshot values worth seeding into
    /// CloudKit. A pristine second device must not publish defaults first and
    /// overwrite custom settings waiting to import from the original device.
    static func hasStoredValues(profileID: UUID, defaults: UserDefaults = .standard) -> Bool {
        scopedBaseKeys.contains {
            defaults.object(forKey: key($0, profileID: profileID)) != nil
        }
    }

    /// An empty local cloud row is ambiguous until the first successful import:
    /// it may be genuinely empty, or it may simply predate another device's
    /// upload. Never let a passive launch publish over that unknown state.
    static func shouldSeedCloudSnapshot(
        cloudJSON: String,
        hasCompletedCloudImport: Bool,
        hasStoredLocalValues: Bool
    ) -> Bool {
        cloudJSON.isEmpty && hasCompletedCloudImport && hasStoredLocalValues
    }

    static func encode(_ snapshot: ProfilePreferencesSnapshot) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> ProfilePreferencesSnapshot? {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ProfilePreferencesSnapshot.self, from: data)
    }

    /// Writes only keys represented by the snapshot. That makes the payload
    /// forward-compatible: an older app won't clear a newer preference it does
    /// not understand, while explicit empty strings still clear known values.
    static func apply(
        _ snapshot: ProfilePreferencesSnapshot,
        profileID: UUID,
        defaults: UserDefaults = .standard
    ) {
        let supported = Set(scopedBaseKeys)
        for (base, value) in snapshot.strings where supported.contains(base) && !booleanBaseKeys.contains(base) {
            defaults.set(value, forKey: key(base, profileID: profileID))
        }
        for (base, value) in snapshot.booleans where supported.contains(base) && booleanBaseKeys.contains(base) {
            defaults.set(value, forKey: key(base, profileID: profileID))
        }
    }

    /// Preserve fields introduced by a newer app when this version publishes a
    /// change to one of the keys it knows about.
    static func preservingUnknownValues(
        in previous: ProfilePreferencesSnapshot?,
        updating current: ProfilePreferencesSnapshot
    ) -> ProfilePreferencesSnapshot {
        guard let previous else { return current }
        let supported = Set(scopedBaseKeys)
        var merged = current
        for (key, value) in previous.strings where !supported.contains(key) {
            merged.strings[key] = value
        }
        for (key, value) in previous.booleans where !supported.contains(key) {
            merged.booleans[key] = value
        }
        return merged
    }

    /// Resolves an import that arrives while this device has an unsaved edit.
    /// Remote values remain authoritative for fields untouched locally; only
    /// values changed since the last applied/saved snapshot are overlaid. This
    /// avoids both losing the pending edit and replacing unrelated changes made
    /// on another device with this device's otherwise-stale snapshot.
    static func merging(
        remote: ProfilePreferencesSnapshot,
        withLocalChanges local: ProfilePreferencesSnapshot,
        since baseline: ProfilePreferencesSnapshot
    ) -> ProfilePreferencesSnapshot {
        var merged = remote
        for (key, value) in local.strings where value != baseline.strings[key] {
            merged.strings[key] = value
        }
        for (key, value) in local.booleans where value != baseline.booleans[key] {
            merged.booleans[key] = value
        }
        return merged
    }

    /// Set once the pre-profile values have been adopted, so the copy never
    /// runs twice — a second pass after the user had switched profiles would
    /// copy one person's layout onto another's.
    static let migrationFlagKey = "profiles.layoutScoped.v1"
    /// The original profile-scoping change listed recommendations in its
    /// migration but the views accidentally kept writing the bare key. This
    /// one-time repair adopts that latest bare value before the views switch to
    /// the correctly scoped key.
    static let recommendationMigrationFlagKey = "profiles.recommendationsScoped.v2"

    /// Adopts the layout someone had before this change as the active profile's.
    /// Without it, upgrading would silently reset every existing install to the
    /// default layout, because the scoped keys start out empty.
    ///
    /// Call once the active profile is known — `ProfileManager` does that during
    /// bootstrap, before any view reads a layout key.
    static func migrateLegacyValuesIfNeeded(defaults: UserDefaults = .standard) {
        // No profile yet means the bare keys are still the live ones; leave them
        // and migrate on the next launch, once bootstrap has settled one.
        guard ActiveProfileStore.current != nil else { return }

        if !defaults.bool(forKey: migrationFlagKey) {
            for base in scopedBaseKeys {
                let scoped = key(base)
                guard scoped != base, defaults.object(forKey: scoped) == nil,
                      let legacy = defaults.object(forKey: base)
                else { continue }
                defaults.set(legacy, forKey: scoped)
            }
            defaults.set(true, forKey: migrationFlagKey)
        }

        if !defaults.bool(forKey: recommendationMigrationFlagKey) {
            let scoped = key(RecommendationSettings.baseEnabledKey)
            if scoped != RecommendationSettings.baseEnabledKey,
               let legacy = defaults.object(forKey: RecommendationSettings.baseEnabledKey)
            {
                // Overwrite the first migration's copy: until this repair, the
                // bare key remained the value the UI actually changed.
                defaults.set(legacy, forKey: scoped)
            }
            defaults.set(true, forKey: recommendationMigrationFlagKey)
        }
    }
}

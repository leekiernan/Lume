//
//  ProfileScopedPreferences.swift
//  Lume
//
//  Layout preferences belong to a person, not a device: which areas appear,
//  which rows each carries, in what order, and the custom rows someone added.
//  They live in UserDefaults (they are small scalars — see `HomeLayoutSettings`),
//  so unlike the catalog's per-content state they are *not* carried by the
//  CloudKit projection swap `CloudSyncEngine.switchProfile` performs. This is
//  what scopes them instead: every layout key is prefixed with the active
//  profile's id, so switching profile switches the whole layout with it.
//
//  Everything else in UserDefaults stays device-wide on purpose — the selected
//  playlist, sync cadence and player engine preferences describe *this device's*
//  setup, not the viewer's taste.
//

import Foundation

nonisolated enum ProfileScopedPreferences {
    /// Scopes a layout key to the active profile. Falls back to the bare key
    /// before a profile exists (first launch, previews, unit tests), which is
    /// also the value the migration below reads from.
    static func key(_ base: String) -> String {
        guard let id = ActiveProfileStore.current else { return base }
        return "profile.\(id.uuidString).\(base)"
    }

    /// Every layout key that is scoped, listed once so the migration can move
    /// all of them and none is forgotten when a new surface is added.
    static var scopedBaseKeys: [String] {
        var keys = [
            AppAreaSettings.baseDisabledAreasKey,
            RecommendationSettings.enabledKey
        ]
        for surface in SectionSurface.allCases {
            keys.append(HomeLayoutSettings.baseSectionOrderKey(surface))
            keys.append(HomeLayoutSettings.baseDisabledSectionsKey(surface))
            keys.append(HomeLayoutSettings.baseHeroSectionKey(surface))
            keys.append(CustomHomeSections.baseStorageKey(surface))
        }
        return keys
    }

    /// Set once the pre-profile values have been adopted, so the copy never
    /// runs twice — a second pass after the user had switched profiles would
    /// copy one person's layout onto another's.
    static let migrationFlagKey = "profiles.layoutScoped.v1"

    /// Adopts the layout someone had before this change as the active profile's.
    /// Without it, upgrading would silently reset every existing install to the
    /// default layout, because the scoped keys start out empty.
    ///
    /// Call once the active profile is known — `ProfileManager` does that during
    /// bootstrap, before any view reads a layout key.
    static func migrateLegacyValuesIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        // No profile yet means the bare keys are still the live ones; leave them
        // and migrate on the next launch, once bootstrap has settled one.
        guard ActiveProfileStore.current != nil else { return }

        for base in scopedBaseKeys {
            let scoped = key(base)
            guard scoped != base, defaults.object(forKey: scoped) == nil,
                  let legacy = defaults.object(forKey: base)
            else { continue }
            defaults.set(legacy, forKey: scoped)
        }
        defaults.set(true, forKey: migrationFlagKey)
    }
}

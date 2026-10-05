import Foundation

/// The work gate is distinct from tab visibility and spoiler/layout preferences.
/// Keep the Sports preference intact when its parent Live TV area is disabled.
nonisolated struct SportsAvailability: Equatable {
    let profileID: UUID?
    let isEnabled: Bool

    init(profileID: UUID?, liveTVEnabled: Bool, sportsEnabled: Bool) {
        self.profileID = profileID
        isEnabled = liveTVEnabled && sportsEnabled
    }

    static func read(profileID: UUID? = ActiveProfileStore.current, defaults: UserDefaults = .standard) -> Self {
        let disabledKey = ProfileScopedPreferences.key(AppAreaSettings.baseDisabledAreasKey, profileID: profileID)
        let sportsKey = ProfileScopedPreferences.key(SportsSyncService.baseEnabledKey, profileID: profileID)
        return Self(
            profileID: profileID,
            liveTVEnabled: AppAreaSettings.isEnabled(.liveTV, disabledRaw: defaults.string(forKey: disabledKey) ?? ""),
            sportsEnabled: defaults.object(forKey: sportsKey) == nil || defaults.bool(forKey: sportsKey)
        )
    }
}

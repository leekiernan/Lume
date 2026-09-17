import Foundation
@testable import Lume
import Testing

/// These touch `UserDefaults.standard` through `ActiveProfileStore`, so they run
/// serialized and restore whatever the host had set.
@Suite(.serialized)
struct ProfileScopedPreferencesTests {
    private static let profileA = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
    private static let profileB = UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!

    /// Runs `body` with `profile` active, then puts the previous value back.
    private func withActiveProfile<T>(_ profile: UUID?, _ body: () throws -> T) rethrows -> T {
        let previous = ActiveProfileStore.current
        ActiveProfileStore.current = profile
        defer { ActiveProfileStore.current = previous }
        return try body()
    }

    // MARK: - Key scoping

    @Test func `keys are prefixed with the active profile`() {
        let key = withActiveProfile(Self.profileA) {
            ProfileScopedPreferences.key("home.sectionOrder.v1")
        }
        #expect(key == "profile.\(Self.profileA.uuidString).home.sectionOrder.v1")
    }

    @Test func `each profile gets its own key`() {
        let first = withActiveProfile(Self.profileA) { ProfileScopedPreferences.key("nav.disabledAreas.v1") }
        let second = withActiveProfile(Self.profileB) { ProfileScopedPreferences.key("nav.disabledAreas.v1") }
        #expect(first != second)
    }

    /// Before a profile exists — first launch, previews, tests — the bare key is
    /// the live one, which is also what the migration reads from.
    @Test func `no profile falls back to the bare key`() {
        let key = withActiveProfile(nil) { ProfileScopedPreferences.key("home.sectionOrder.v1") }
        #expect(key == "home.sectionOrder.v1")
    }

    // MARK: - Coverage

    /// Every layout key must be in the scoped list, or switching profile would
    /// carry part of one person's layout into another's.
    @Test func `every layout key is scoped`() {
        withActiveProfile(Self.profileA) {
            var expected: Set<String> = [
                AppAreaSettings.disabledAreasKey,
                ProfileScopedPreferences.key(RecommendationSettings.enabledKey)
            ]
            for surface in SectionSurface.allCases {
                expected.insert(HomeLayoutSettings.sectionOrderKey(surface))
                expected.insert(HomeLayoutSettings.disabledSectionsKey(surface))
                expected.insert(CustomHomeSections.storageKey(surface))
            }
            let listed = Set(ProfileScopedPreferences.scopedBaseKeys.map(ProfileScopedPreferences.key))
            #expect(listed == expected)
        }
    }

    @Test func `scoped keys are unique across surfaces`() {
        withActiveProfile(Self.profileA) {
            let keys = ProfileScopedPreferences.scopedBaseKeys
            #expect(Set(keys).count == keys.count)
        }
    }

    /// The device's own setup stays device-wide: a second profile shouldn't have
    /// to pick its playlist or re-choose a playback engine.
    @Test func `device preferences are not scoped`() {
        let deviceKeys = [PlaylistSelectionStore.key, SyncFrequency.storageKey]
        for key in deviceKeys {
            #expect(!ProfileScopedPreferences.scopedBaseKeys.contains(key))
        }
    }

    // MARK: - Migration

    @Test func `legacy values are adopted by the first profile`() throws {
        let defaults = try #require(UserDefaults(suiteName: "ProfileScopedPreferencesTests.adopt"))
        defaults.removePersistentDomain(forName: "ProfileScopedPreferencesTests.adopt")

        let base = HomeLayoutSettings.baseSectionOrderKey(.home)
        defaults.set("favorites,forYou", forKey: base)

        withActiveProfile(Self.profileA) {
            ProfileScopedPreferences.migrateLegacyValuesIfNeeded(defaults: defaults)
            #expect(defaults.string(forKey: HomeLayoutSettings.sectionOrderKey(.home)) == "favorites,forYou")
        }
        #expect(defaults.bool(forKey: ProfileScopedPreferences.migrationFlagKey))
    }

    /// The copy must never run twice: a second pass after the viewer had
    /// switched would stamp the old global layout onto whoever is active now.
    @Test func `migration runs only once`() throws {
        let defaults = try #require(UserDefaults(suiteName: "ProfileScopedPreferencesTests.once"))
        defaults.removePersistentDomain(forName: "ProfileScopedPreferencesTests.once")

        let base = HomeLayoutSettings.baseSectionOrderKey(.home)
        defaults.set("favorites", forKey: base)
        withActiveProfile(Self.profileA) {
            ProfileScopedPreferences.migrateLegacyValuesIfNeeded(defaults: defaults)
        }

        withActiveProfile(Self.profileB) {
            ProfileScopedPreferences.migrateLegacyValuesIfNeeded(defaults: defaults)
            #expect(defaults.string(forKey: HomeLayoutSettings.sectionOrderKey(.home)) == nil)
        }
    }

    /// A profile that has already customised its layout must not be overwritten.
    @Test func `migration never overwrites an existing value`() throws {
        let defaults = try #require(UserDefaults(suiteName: "ProfileScopedPreferencesTests.keep"))
        defaults.removePersistentDomain(forName: "ProfileScopedPreferencesTests.keep")

        let base = HomeLayoutSettings.baseSectionOrderKey(.home)
        defaults.set("favorites", forKey: base)
        withActiveProfile(Self.profileA) {
            defaults.set("forYou", forKey: HomeLayoutSettings.sectionOrderKey(.home))
            ProfileScopedPreferences.migrateLegacyValuesIfNeeded(defaults: defaults)
            #expect(defaults.string(forKey: HomeLayoutSettings.sectionOrderKey(.home)) == "forYou")
        }
    }

    /// Nothing to scope to yet — leave the bare keys alone and try again next
    /// launch, once bootstrap has settled a profile.
    @Test func `migration defers until a profile exists`() throws {
        let defaults = try #require(UserDefaults(suiteName: "ProfileScopedPreferencesTests.defer"))
        defaults.removePersistentDomain(forName: "ProfileScopedPreferencesTests.defer")

        withActiveProfile(nil) {
            ProfileScopedPreferences.migrateLegacyValuesIfNeeded(defaults: defaults)
        }
        #expect(!defaults.bool(forKey: ProfileScopedPreferences.migrationFlagKey))
    }
}

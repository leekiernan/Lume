import Foundation
@testable import Lume
import Testing

/// D2's area-generation token. The point of the pairing API is that the area
/// set and the generation that stamps it cannot drift apart, so these assert
/// the *pair*, never one half.
@Suite("Area generation token")
struct AreaGenerationTokenTests {
    private static let profile = UUID(uuidString: "00000000-0000-0000-0000-00000000C003")!

    /// A throwaway domain, so nothing here depends on or disturbs the host's
    /// `UserDefaults.standard`.
    private func withDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let name = "AreaGenerationTokenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        return try body(defaults)
    }

    @Test func `a profile with nothing stored starts at the initial generation`() {
        withDefaults { defaults in
            let state = AppAreaSettings.areaState(profileID: Self.profile, defaults: defaults)
            #expect(state.disabledRaw.isEmpty)
            #expect(state.generation == .initial)
        }
    }

    @Test func `persisting the area set always moves the generation with it`() {
        withDefaults { defaults in
            let first = AppAreaSettings.persist(disabledRaw: "liveTV", profileID: Self.profile, defaults: defaults)
            #expect(first.disabledRaw == "liveTV")
            #expect(first.generation == AreaGenerationToken.initial.bumped())

            let reread = AppAreaSettings.areaState(profileID: Self.profile, defaults: defaults)
            #expect(reread == first)

            let second = AppAreaSettings.persist(disabledRaw: "", profileID: Self.profile, defaults: defaults)
            #expect(second.disabledRaw.isEmpty)
            #expect(second.generation == first.generation.bumped())
        }
    }

    /// Storing the same value is still a write, and a job that captured the
    /// previous pair has no way to tell a rewrite from a change — so the
    /// generation moves and the job is superseded rather than trusted.
    @Test func `rewriting the same value still bumps the generation`() {
        withDefaults { defaults in
            let first = AppAreaSettings.persist(disabledRaw: "movies", profileID: Self.profile, defaults: defaults)
            let second = AppAreaSettings.persist(disabledRaw: "movies", profileID: Self.profile, defaults: defaults)
            #expect(second.disabledRaw == first.disabledRaw)
            #expect(second.generation != first.generation)
        }
    }

    @Test func `switching an area off moves the pair together`() {
        withDefaults { defaults in
            let state = AppAreaSettings.setEnabled(false, for: .liveTV, profileID: Self.profile, defaults: defaults)
            #expect(!AppAreaSettings.isEnabled(.liveTV, disabledRaw: state.disabledRaw))
            #expect(state.generation == AreaGenerationToken.initial.bumped())
            #expect(AppAreaSettings.areaState(profileID: Self.profile, defaults: defaults) == state)
        }
    }

    /// The last enabled area cannot be switched off. Nothing changed, so
    /// nothing is superseded either.
    @Test func `a refused toggle leaves the generation alone`() {
        withDefaults { defaults in
            var state = AppAreaSettings.AreaState(disabledRaw: "", generation: .initial)
            for area in [AppArea.movies, .series, .liveTV] {
                state = AppAreaSettings.setEnabled(false, for: area, profileID: Self.profile, defaults: defaults)
            }
            #expect(AppAreaSettings.enabledAreas(disabledRaw: state.disabledRaw) == [.home])

            let refused = AppAreaSettings.setEnabled(false, for: .home, profileID: Self.profile, defaults: defaults)
            #expect(refused == state)
        }
    }

    /// Generations are per profile, like the area set they stamp — one
    /// person's toggling must not supersede another's in-flight work.
    @Test func `each profile carries its own generation`() {
        withDefaults { defaults in
            let other = UUID(uuidString: "00000000-0000-0000-0000-00000000D004")!
            AppAreaSettings.persist(disabledRaw: "series", profileID: Self.profile, defaults: defaults)
            AppAreaSettings.persist(disabledRaw: "series", profileID: Self.profile, defaults: defaults)

            #expect(AppAreaSettings.areaState(profileID: Self.profile, defaults: defaults).generation.rawValue == 2)
            #expect(AppAreaSettings.areaState(profileID: other, defaults: defaults).generation == .initial)
            #expect(AppAreaSettings.areaState(profileID: other, defaults: defaults).disabledRaw.isEmpty)
        }
    }

    @Test func `a cloud preference import advances the device-local generation`() {
        withDefaults { defaults in
            let snapshot = ProfilePreferencesSnapshot(
                strings: [AppAreaSettings.baseDisabledAreasKey: "liveTV"],
                booleans: [:]
            )

            ProfileScopedPreferences.apply(snapshot, profileID: Self.profile, defaults: defaults)

            let state = AppAreaSettings.areaState(profileID: Self.profile, defaults: defaults)
            #expect(state.disabledRaw == "liveTV")
            #expect(state.generation == AreaGenerationToken.initial.bumped())
        }
    }

    @Test func `the generation key is profile scoped under the documented name`() {
        #expect(AppAreaSettings.baseAreaGenerationKey == "nav.areaGeneration.v1")
        #expect(
            AppAreaSettings.areaGenerationKey(profileID: Self.profile)
                == "profile.\(Self.profile.uuidString).nav.areaGeneration.v1"
        )
        #expect(AppAreaSettings.areaGenerationKey(profileID: nil) == "nav.areaGeneration.v1")
    }

    /// A stored value larger than `Int64.max` has to survive the round trip —
    /// which is why the generation is stored as a string rather than going
    /// through `UserDefaults`' integer accessors.
    @Test func `a generation beyond Int64 round trips`() {
        withDefaults { defaults in
            let large = UInt64.max - 1
            defaults.set(String(large), forKey: AppAreaSettings.areaGenerationKey(profileID: Self.profile))
            let state = AppAreaSettings.areaState(profileID: Self.profile, defaults: defaults)
            #expect(state.generation.rawValue == large)
            #expect(state.generation.bumped().rawValue == UInt64.max)
            // Wrapping, not trapping.
            #expect(state.generation.bumped().bumped().rawValue == 0)
        }
    }
}

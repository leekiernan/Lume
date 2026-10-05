import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState)
struct SportsAvailabilityReactionTests {
    private func preferences() -> (UserDefaults, String) {
        let suite = "sports.availability.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func seed(_ key: String, profile: UUID, container: ModelContainer, defaults: UserDefaults) throws {
        defaults.set(true, forKey: SportsFollowService.preFollowStampKey(for: profile))
        container.mainContext.insert(SyncedSportsFollow(key: key, kindRaw: "league", profileID: profile))
        try container.mainContext.save()
    }

    private func notify(_ defaults: UserDefaults) {
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    @Test func `standalone preference changes clear and restore follows without changing the sports switch`() async throws {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        let profile = UUID()
        ActiveProfileStore.current = profile
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try makeProfileTestContainer()
        let key = "espn:soccer/ger.1"
        try seed(key, profile: profile, container: container, defaults: defaults)
        let sync = SportsSyncService()
        let service = SportsFollowService(defaults: defaults, preferences: defaults, sync: sync)
        service.configure(container: container)
        #expect(service.followedLeagueIds == [key])

        let sportsKey = ProfileScopedPreferences.key(SportsSyncService.baseEnabledKey, profileID: profile)
        let areasKey = AppAreaSettings.disabledAreasKey(profileID: profile)
        defaults.set(true, forKey: sportsKey)
        defaults.set("liveTV", forKey: areasKey)
        notify(defaults)
        try await waitUntil { service.follows.isEmpty }
        #expect(service.followedLeagueIds.isEmpty)
        #expect(defaults.bool(forKey: sportsKey))

        defaults.set("", forKey: areasKey)
        notify(defaults)
        try await waitUntil { service.followedLeagueIds == [key] }
        #expect(service.followedLeagueIds == [key])
        defaults.set(false, forKey: sportsKey)
        notify(defaults)
        try await waitUntil { service.follows.isEmpty }
        #expect(service.followedLeagueIds.isEmpty)
        defaults.set(true, forKey: sportsKey)
        notify(defaults)
        try await waitUntil { service.followedLeagueIds == [key] }
        #expect(service.followedLeagueIds == [key])
    }

    @Test func `profile and cloud reloads replace the snapshot without a mounted view`() async throws {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        let first = UUID()
        let second = UUID()
        ActiveProfileStore.current = first
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try makeProfileTestContainer()
        let firstKey = "espn:soccer/ger.1"
        let secondKey = "espn:soccer/eng.1"
        try seed(firstKey, profile: first, container: container, defaults: defaults)
        try seed(secondKey, profile: second, container: container, defaults: defaults)
        let sync = SportsSyncService()
        let service = SportsFollowService(defaults: defaults, preferences: defaults, sync: sync)
        service.configure(container: container)
        #expect(service.followedLeagueIds == [firstKey])

        ActiveProfileStore.current = second
        notify(defaults)
        try await waitUntil { service.followedLeagueIds == [secondKey] }
        #expect(service.followedLeagueIds == [secondKey])

        // Cloud follows can change while availability is unchanged; the explicit
        // reconcile reload must not be deduplicated as a preference notification.
        try seed(firstKey, profile: second, container: container, defaults: defaults)
        service.reload()
        #expect(Set(service.followedLeagueIds) == [firstKey, secondKey])
    }

    @Test func `tab spoiler and unrelated area changes do not reload cloud follows`() async throws {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        let profile = UUID()
        ActiveProfileStore.current = profile
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try makeProfileTestContainer()
        let key = "espn:soccer/ger.1"
        try seed(key, profile: profile, container: container, defaults: defaults)
        let sync = SportsSyncService()
        let service = SportsFollowService(defaults: defaults, preferences: defaults, sync: sync)
        service.configure(container: container)

        try seed("espn:soccer/eng.1", profile: profile, container: container, defaults: defaults)
        defaults.set(false, forKey: ProfileScopedPreferences.key(SportsSyncService.baseTabEnabledKey, profileID: profile))
        defaults.set(true, forKey: ProfileScopedPreferences.key(SportsSyncService.baseHideScoresKey, profileID: profile))
        defaults.set("movies", forKey: AppAreaSettings.disabledAreasKey(profileID: profile))
        notify(defaults)
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.followedLeagueIds == [key])
        service.reload()
        #expect(service.followedLeagueIds.count == 2)
    }

    @Test func `reload warms the leagues from its new snapshot rather than the previous follows`() throws {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        let profile = UUID()
        ActiveProfileStore.current = profile
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try makeProfileTestContainer()
        let key = "espn:soccer/ger.1"
        try seed(key, profile: profile, container: container, defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SportsCacheStore(directory: directory)
        cache.save(SportsLeagueSnapshot(fetchedAt: Date()), for: key)
        let store = SportsStore(cache: cache)
        let sync = SportsSyncService(store: store)
        let follows = SportsFollowService(defaults: defaults, preferences: defaults, sync: sync)
        sync.configure(provider: EmptyAvailabilityProvider(), followSource: follows)
        #expect(store.snapshot(for: key) == nil)
        follows.configure(container: container)
        #expect(store.snapshot(for: key) != nil)
    }

    @Test func `reload waits until manager and persisted profile agree`() async throws {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        let first = UUID()
        let second = UUID()
        ActiveProfileStore.current = first
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try makeProfileTestContainer()
        try seed("espn:soccer/ger.1", profile: first, container: container, defaults: defaults)
        try seed("espn:soccer/eng.1", profile: second, container: container, defaults: defaults)
        let coordinator = CloudSyncCoordinator(
            catalogContainer: container, cloudContainer: container,
            cloudKitContainerIdentifier: "iCloud.lume.tests.invalid", cloudKitEnabled: false
        )
        let manager = ProfileManager(catalogContainer: container, cloudContainer: container, coordinator: coordinator)
        let sync = SportsSyncService()
        let follows = SportsFollowService(defaults: defaults, preferences: defaults, sync: sync)
        follows.configure(container: container, profileManager: manager)

        // Simulate the interval between the engine's swap and the manager's
        // main-actor publication. The notification must not read old follows
        // under new preferences, nor mark the new scope as already applied.
        ActiveProfileStore.current = second
        defaults.set("liveTV", forKey: AppAreaSettings.disabledAreasKey(profileID: second))
        notify(defaults)
        try await Task.sleep(for: .milliseconds(20))
        #expect(follows.followedLeagueIds == ["espn:soccer/ger.1"])
        ActiveProfileStore.current = first
        follows.reload()
        #expect(follows.followedLeagueIds == ["espn:soccer/ger.1"])
    }
}

private nonisolated struct EmptyAvailabilityProvider: SportsDataProvider {
    func fixtures(league _: SportsLeague, month _: DateComponents) async throws -> [SportsFixture] {
        []
    }

    func fixtures(league _: SportsLeague, day _: Date) async throws -> [SportsFixture] {
        []
    }

    func teams(league _: SportsLeague) async throws -> [SportsTeam] {
        []
    }

    func standings(league _: SportsLeague) async throws -> [SportsStandingRow] {
        []
    }

    func eventDetail(league _: SportsLeague, eventId _: String) async throws -> SportsEventDetail? {
        nil
    }
}

import Foundation
@testable import Lume
import Testing

/// Deliberately ignores cancellation, like a response already arriving from an
/// external client. Publication must be fenced by the service, not the stub.
private actor SuspendedSportsProvider: SportsDataProvider {
    private let fixture: SportsFixture
    private var pending: [CheckedContinuation<[SportsFixture], Never>] = []
    private var ready: CheckedContinuation<Void, Never>?
    private var expectedRequests = 0

    init(id: String) {
        fixture = SportsFixture(
            id: id, leagueId: "espn:soccer/ger.1", leagueName: "Bundesliga",
            leagueAbbreviation: "BUND", startDate: Date(), status: SportsFixtureStatus(state: .scheduled)
        )
    }

    func fixtures(league _: SportsLeague, month _: DateComponents) async throws -> [SportsFixture] {
        await withCheckedContinuation { continuation in
            pending.append(continuation)
            if pending.count >= expectedRequests {
                ready?.resume()
                ready = nil
            }
        }
    }

    func waitForRequests(_ count: Int) async {
        expectedRequests = count
        guard pending.count < count else { return }
        await withCheckedContinuation { ready = $0 }
    }

    func release() {
        let completions = pending
        pending = []
        for completion in completions {
            completion.resume(returning: [fixture])
        }
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

private nonisolated struct AvailabilityFollowSource: SportsFollowSource {
    let followedLeagueIds = ["espn:soccer/ger.1"]
    let followedTeamIds: [String] = []
}

@MainActor
@Suite(.globalState)
struct SportsAvailabilityLifecycleTests {
    @Test(arguments: [false, true])
    func `obsolete refresh cannot publish or clear a replacement refresh`(switchProfile: Bool) async throws {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        ActiveProfileStore.current = UUID()
        let sportsKey = SportsSyncService.enabledKey
        defer { UserDefaults.standard.removeObject(forKey: sportsKey) }
        let suite = "sports.lifecycle.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SportsStore(cache: SportsCacheStore(directory: directory))
        let service = SportsSyncService(store: store, followSource: AvailabilityFollowSource(), defaults: defaults)
        let oldProvider = SuspendedSportsProvider(id: "old")
        service.configure(provider: oldProvider)
        let oldRefresh = Task { await service.refreshAll() }
        let count = SportsSyncService.monthsToFetch(for: Date()).count
        await oldProvider.waitForRequests(count)
        #expect(service.isSyncing)

        if switchProfile {
            ActiveProfileStore.current = UUID()
        } else {
            UserDefaults.standard.set(false, forKey: sportsKey)
        }
        service.availabilityDidChange()
        #expect(!service.isSyncing)
        if !switchProfile { UserDefaults.standard.set(true, forKey: sportsKey) }

        let newProvider = SuspendedSportsProvider(id: "new")
        service.configure(provider: newProvider)
        let newRefresh = Task { await service.refreshAll() }
        await newProvider.waitForRequests(count)
        await oldProvider.release()
        await oldRefresh.value
        #expect(service.isSyncing)
        #expect(store.snapshot(for: "espn:soccer/ger.1") == nil)
        #expect(service.lastRefresh == nil)

        await newProvider.release()
        await newRefresh.value
        #expect(!service.isSyncing)
        #expect(store.snapshot(for: "espn:soccer/ger.1")?.fixtures.map(\.id) == ["new"])
        #expect(service.lastRefresh != nil)
    }
}

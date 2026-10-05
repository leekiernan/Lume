//
//  SportsSyncService.swift
//  Lume
//
//  Owns the Sports Hub's refresh and its live-score polling. There is no schedule:
//  sports data is a short-lived cache (`freshness`), re-fetched whenever a sports
//  surface asks for it — the Home rail or hub appearing, the app returning to the
//  foreground, and every tick of the live loop while one of them is on screen.
//
//  Two refresh shapes:
//  - the full refresh (`refreshIfStale`): whole months plus standings (and teams
//    once a week) for every followed league whose snapshot is older than
//    `freshness`;
//  - the live poll (`beginLivePolling`): every 60 s while a sports surface is
//    visible, the full refresh for any league gone stale plus the days of every
//    live or overdue fixture.
//
//  A refresh hits ESPN (not the provider host), so the one-connection account cap
//  that gates `EPGSyncService` does not apply here — the two never compete. The
//  fetching runs on a utility Task; only the finished, `Sendable` snapshots cross
//  back to `SportsStore` on the main actor. A failure leaves the previous snapshot
//  in place and flags `SportsStore.refreshError` rather than blanking the hub; the
//  league stays stale, so the next surface to appear tries again.
//

import Foundation
import Observation
import OSLog
#if os(iOS)
    import UIKit
#endif

// MARK: - Follow source

/// The active profile's followed leagues and teams; tests supply stubs.
nonisolated protocol SportsFollowSource: Sendable {
    var followedLeagueIds: [String] { get }
    var followedTeamIds: [String] { get }
}

/// Empty default keeps the shared service inert until it is configured.
nonisolated struct EmptySportsFollowSource: SportsFollowSource {
    var followedLeagueIds: [String] {
        []
    }

    var followedTeamIds: [String] {
        []
    }
}

// MARK: - Sync service

@Observable
final class SportsSyncService {
    static let shared = SportsSyncService()

    private(set) var isSyncing = false

    private var provider: (any SportsDataProvider)?
    private var followSource: any SportsFollowSource
    private let store: SportsStore
    private let crestTints: SportsCrestTintCache
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var refreshToken = RequestToken()
    private var availability: SportsAvailability?
    /// When each league was last sent a full refresh, successful or not. ESPN
    /// answers a failure and an off-season league alike with nothing, and either
    /// leaves the league stale — this keeps it from being re-asked on every
    /// appearance of a surface (a tvOS Home rail appears on every scroll past it).
    private var lastAttempt: [String: Date] = [:]

    /// Whether the app is foregrounded, updated from the scene-phase hook. Live
    /// polling pauses while the app is not active; coming back to the foreground
    /// refreshes whatever went stale, so hours in the background never leave a
    /// game "live" on the rail.
    var isForeground = true {
        didSet {
            if isForeground, !oldValue { refreshIfStale() }
        }
    }

    private var liveTask: Task<Void, Never>?
    private var liveClients = 0

    /// `@AppStorage` key for the Sports tab toggle.
    nonisolated static let baseTabEnabledKey = "sports.tabEnabled"
    static var tabEnabledKey: String {
        ProfileScopedPreferences.key(baseTabEnabledKey)
    }

    /// Sports is an optional Live TV feature. Its own switch gives a profile a
    /// way to hide the hub while retaining the rest of Live TV.
    nonisolated static let baseEnabledKey = "sports.enabled.v1"
    static var enabledKey: String {
        ProfileScopedPreferences.key(baseEnabledKey)
    }

    nonisolated static let enabledDefault = true

    /// `@AppStorage` key for spoiler-free fixture cards: no score, no winner
    /// emphasis. The game detail still shows the score once opened.
    nonisolated static let baseHideScoresKey = "sports.hideScores"
    static var hideScoresKey: String {
        ProfileScopedPreferences.key(baseHideScoresKey)
    }

    /// Default for the Sports tab toggle: on everywhere except iPhone, where iOS
    /// fits four regular tabs plus the Search pill — a fifth would push both
    /// Sports and Search into "More". There the Home rail's "See All" opens the
    /// hub and the tab can be enabled in Settings › Sports.
    static var tabEnabledDefault: Bool {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom != .phone
        #else
            true
        #endif
    }

    private static let baseLastRefreshKey = "lume.sportsLastRefresh"
    private static var lastRefreshKey: String {
        ProfileScopedPreferences.key(baseLastRefreshKey)
    }

    /// Teams (crests, colours) change rarely; reuse the cached roster for a week.
    private nonisolated static let teamCacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// How long a league's full refresh counts as current. Kickoff times move and
    /// fixtures get added through the day, and a refresh is a handful of small
    /// ESPN requests per league, so this is kept short: any surface appearing
    /// after it re-fetches.
    nonisolated static let freshness: TimeInterval = 5 * 60
    /// How often live scores re-poll while a sports surface is visible.
    static let livePollInterval: TimeInterval = 60
    /// How soon a league whose last full refresh came back empty is asked again.
    static let retryInterval: TimeInterval = 60
    /// How far back a fixture still called "scheduled" or "live" past its kickoff
    /// keeps the poll going. Beyond this the month refresh owns it; the bound
    /// keeps a fixture the provider dropped from polling forever.
    nonisolated static let overdueLookback: TimeInterval = 3 * 24 * 60 * 60
    /// How many leagues refresh at once — ESPN, not the capped provider host.
    private static let maxConcurrentLeagueRefreshes = 4

    init(
        // Nil for the shared store: a default argument is evaluated outside
        // the main actor, where `SportsStore.shared` can't be read.
        store: SportsStore? = nil,
        followSource: any SportsFollowSource = EmptySportsFollowSource(),
        defaults: UserDefaults = .standard,
        crestTints: SportsCrestTintCache = .shared
    ) {
        self.store = store ?? .shared
        self.followSource = followSource
        self.defaults = defaults
        self.crestTints = crestTints
    }

    /// Wires the data source and the follow service. Warms the store from disk
    /// so the hub renders before the first network refresh.
    func configure(
        provider: any SportsDataProvider = ESPNClient.shared,
        followSource: (any SportsFollowSource)? = nil
    ) {
        self.provider = provider
        if let followSource { self.followSource = followSource }
        availabilityDidChange()
    }

    /// Re-evaluates the active profile's Live TV/Sports switches. This lives at
    /// the service boundary so background callers cannot keep ESPN work alive
    /// after the user switches either feature off.
    func availabilityDidChange() {
        let current = SportsAvailability.read()
        let profileChanged = availability.map { $0.profileID != current.profileID } ?? false
        availability = current
        if profileChanged || !current.isEnabled {
            refreshToken = RequestToken()
            task?.cancel()
            liveTask?.cancel()
            task = nil
            liveTask = nil
            if !current.isEnabled { liveClients = 0 }
            isSyncing = false
            lastAttempt.removeAll()
        }
        guard current.isEnabled else { return }
        store.loadCached(leagueIds: leaguesToRefresh())
        if profileChanged { startLiveLoopIfNeeded() }
    }

    /// A Sports surface is meaningful only when both the parent Live TV area
    /// and this profile's optional Sports feature are on.
    static var isEnabled: Bool {
        SportsAvailability.read().isEnabled
    }

    // MARK: - Triggers

    /// Manual pull (a "Refresh" affordance): refreshes every followed league now,
    /// fresh or not.
    func syncNow() {
        guard Self.isEnabled else { return }
        Task { await refreshAll() }
    }

    /// Surface-appear / foreground / follow-change trigger: refreshes every
    /// followed league whose snapshot is missing or older than `freshness`. Cheap
    /// to call as often as a view likes — with everything fresh it sends nothing.
    func refreshIfStale() {
        guard Self.isEnabled else { return }
        Task { await refreshStale() }
    }

    /// One full refresh over the followed leagues. Awaitable so callers (and tests)
    /// can sequence work after it; `syncNow()` wraps it in a fire-and-forget Task.
    func refreshAll() async {
        await refresh(leagueIds: leaguesToRefresh().filter { SportsCatalog.league(id: $0) != nil })
    }

    /// One refresh over the stale followed leagues. Awaitable so tests can
    /// sequence on it (and move the clock); `refreshIfStale()` wraps it in a
    /// fire-and-forget Task.
    func refreshStale(now: Date = Date()) async {
        await refresh(leagueIds: staleLeagueIds(now: now))
    }

    /// Followed leagues with no snapshot, or one older than `freshness`, that were
    /// not already tried within `retryInterval`. Warms the store from disk first,
    /// so a snapshot that is merely not loaded yet is judged by its own age. A
    /// league the catalogue doesn't know can never be fetched, so it is never
    /// counted stale.
    private func staleLeagueIds(now: Date = Date()) -> [String] {
        let ids = leaguesToRefresh()
        store.loadCached(leagueIds: ids)
        return ids.filter { id in
            guard SportsCatalog.league(id: id) != nil, !Self.isFresh(store.snapshot(for: id), now: now) else {
                return false
            }
            guard let attempted = lastAttempt[id] else { return true }
            return now.timeIntervalSince(attempted) >= Self.retryInterval
        }
    }

    /// Runs one full refresh of the given leagues. A refresh already in flight is
    /// joined rather than doubled — it was started moments ago by another surface
    /// and covers the same followed set.
    private func refresh(leagueIds: [String]) async {
        guard !Task.isCancelled, Self.isEnabled, provider != nil else { return }
        if let task {
            await task.value
            return
        }
        guard !leagueIds.isEmpty else { return }
        let token = RequestToken()
        refreshToken = token
        let months = Self.monthsToFetch(for: Date())
        let pass = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await performRefresh(leagueIds: leagueIds, months: months)
        }
        task = pass
        isSyncing = true
        await pass.value
        // A cancelled pass may finish after a new profile has started its own.
        guard refreshToken == token else { return }
        task = nil
        isSyncing = false
    }

    /// The last successful refresh timestamp, for display in Settings. `nil` until
    /// the first successful refresh.
    var lastRefresh: Date? {
        lastRefreshDate
    }

    private var lastRefreshDate: Date? {
        get {
            let stamp = defaults.double(forKey: Self.lastRefreshKey)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastRefreshKey)
        }
    }

    // MARK: - Live scores

    /// Called by a sports surface (tab / rail / detail) as it appears. Reference
    /// counted, so overlapping surfaces keep one shared 60s loop alive.
    func beginLivePolling() {
        guard Self.isEnabled else { return }
        liveClients += 1
        startLiveLoopIfNeeded()
    }

    /// Called as a sports surface disappears; the loop stops when the last one goes.
    func endLivePolling() {
        liveClients = max(0, liveClients - 1)
        if liveClients == 0 {
            liveTask?.cancel()
            liveTask = nil
        }
    }

    private func startLiveLoopIfNeeded() {
        guard liveTask == nil, liveClients > 0 else { return }
        liveTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self, Self.isEnabled, liveClients > 0 else { break }
                if isForeground, !ContentIndexingService.shared.isPlaybackActive {
                    await pollTick()
                }
                try? await Task.sleep(for: .seconds(Self.livePollInterval))
            }
            if !Task.isCancelled { self?.liveTask = nil }
        }
    }

    /// One pass of the live loop: a full refresh for every league gone stale while
    /// the surface stayed open, then the days of the live or overdue fixtures of
    /// the rest — the full refresh already brought those leagues' days.
    private func pollTick() async {
        let stale = staleLeagueIds()
        await refresh(leagueIds: stale)
        let rest = leaguesToRefresh().filter { !stale.contains($0) }
        let days = Self.pollDays(fixtures: store.fixtures(inLeagues: rest), now: Date())
        if !days.isEmpty {
            await refreshDays(leagueIds: rest, days: days)
        }
    }

    // MARK: - Refresh

    /// Refreshes the given leagues and returns the ids that actually came back
    /// with something — the caller's evidence of which fetches succeeded, as
    /// opposed to which were merely attempted.
    @discardableResult
    private func performRefresh(leagueIds: [String], months: [DateComponents]) async -> Set<String> {
        guard !Task.isCancelled, Self.isEnabled else { return [] }
        let scope = SportsAvailability.read()
        let interval = Perf.begin(.sportsFixtureRefresh)
        defer { Perf.end(interval) }
        let leagues = leagueIds.compactMap { SportsCatalog.league(id: $0) }
        let startedAt = Date()
        for league in leagues {
            lastAttempt[league.id] = startedAt
        }
        let refreshed = await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = leagues.makeIterator()
            for _ in 0 ..< Self.maxConcurrentLeagueRefreshes {
                guard let league = iterator.next() else { break }
                group.addTask { await (league.id, self.refreshLeague(league, months: months)) }
            }
            var succeeded: Set<String> = []
            while let (leagueId, success) = await group.next() {
                if success { succeeded.insert(leagueId) }
                if !Task.isCancelled, let league = iterator.next() {
                    group.addTask { await (league.id, self.refreshLeague(league, months: months)) }
                }
            }
            return succeeded
        }
        guard !Task.isCancelled, scope == SportsAvailability.read(), Self.isEnabled else { return [] }
        // "Scores unavailable" only when nothing followed is current: a pass over
        // one off-season league that answered empty is not an outage while the
        // other leagues refreshed a minute ago.
        if refreshed.isEmpty {
            let now = Date()
            if !leaguesToRefresh().contains(where: { Self.isFresh(store.snapshot(for: $0), now: now) }) {
                store.markRefreshFailed()
            }
        } else {
            lastRefreshDate = Date()
        }
        return refreshed
    }

    /// Fetches one league's months, teams (reusing the weekly roster cache) and
    /// standings, then publishes a merged snapshot. Returns whether anything fresh
    /// arrived; on a total failure it leaves the existing snapshot untouched.
    private func refreshLeague(_ league: SportsLeague, months: [DateComponents]) async -> Bool {
        guard !Task.isCancelled, Self.isEnabled, let provider else { return false }
        let existing = store.snapshot(for: league.id)
        let teamsCacheFresh = Self.teamsCacheIsFresh(existing)

        async let fetchedMonths = Self.fetchFixtures(provider: provider, league: league, months: months)
        async let fetchedTeams = teamsCacheFresh ? [] : ((try? provider.teams(league: league)) ?? [])
        async let fetchedStandings = (try? provider.standings(league: league)) ?? []

        let (monthFixtures, gotFixtures) = await fetchedMonths
        let teamsResult = await fetchedTeams
        let standingsResult = await fetchedStandings

        var fixturesById: [String: SportsFixture] = [:]
        if let existing {
            for fixture in existing.fixtures {
                fixturesById[fixture.id] = fixture
            }
        }
        for fixture in monthFixtures {
            fixturesById[fixture.id] = fixture
        }

        let teams: [SportsTeam]
        let teamsFetchedAt: Date?
        var gotTeams = false
        if teamsCacheFresh {
            teams = existing?.teams ?? []
            teamsFetchedAt = existing?.teamsFetchedAt
        } else if teamsResult.isEmpty {
            teams = existing?.teams ?? []
            teamsFetchedAt = existing?.teamsFetchedAt
        } else {
            teams = teamsResult
            teamsFetchedAt = Date()
            gotTeams = true
        }

        let standings = standingsResult.isEmpty ? (existing?.standings ?? []) : standingsResult

        guard !Task.isCancelled, Self.isEnabled, gotFixtures || gotTeams || !standingsResult.isEmpty else { return false }

        let snapshot = SportsLeagueSnapshot(
            fetchedAt: Date(),
            fixtures: Self.retainedFixtures(Array(fixturesById.values)),
            standings: standings,
            teams: teams,
            teamsFetchedAt: teamsFetchedAt
        )
        await publish(snapshot, for: league.id)
        return true
    }

    /// Stores a snapshot with every colourless team tinted from its crest. Tints
    /// already known go in at once; crests never analysed are fetched after the
    /// snapshot is on screen, then merged into whatever the store holds by then.
    private func publish(_ snapshot: SportsLeagueSnapshot, for leagueId: String) async {
        let crests = snapshot.crestsNeedingTint
        let known = await crestTints.cachedTints(for: crests)
        guard !Task.isCancelled, Self.isEnabled else { return }
        store.update(snapshot.withCrestTints(from: known), for: leagueId)

        let unseen = await crestTints.unseen(crests)
        guard !Task.isCancelled, Self.isEnabled, !unseen.isEmpty else { return }
        let learned = await crestTints.learnTints(for: unseen)
        guard !Task.isCancelled, Self.isEnabled, !learned.isEmpty, let current = store.snapshot(for: leagueId) else { return }
        store.update(current.withCrestTints(from: learned), for: leagueId)
    }

    /// Whether the cached roster is present and still within its week-long life.
    private nonisolated static func teamsCacheIsFresh(_ existing: SportsLeagueSnapshot?) -> Bool {
        guard let existing, !existing.teams.isEmpty, let fetchedAt = existing.teamsFetchedAt else {
            return false
        }
        return Date().timeIntervalSince(fetchedAt) < teamCacheLifetime
    }

    /// Fetches a league's months concurrently and merges them in month order, so
    /// per-league latency is the slowest month rather than their sum.
    private nonisolated static func fetchFixtures(
        provider: any SportsDataProvider,
        league: SportsLeague,
        months: [DateComponents]
    ) async -> (fixtures: [SportsFixture], gotAny: Bool) {
        await withTaskGroup(of: (Int, [SportsFixture]).self) { group in
            for (index, month) in months.enumerated() {
                group.addTask {
                    await (index, (try? provider.fixtures(league: league, month: month)) ?? [])
                }
            }
            var byIndex: [Int: [SportsFixture]] = [:]
            for await (index, fetched) in group {
                byIndex[index] = fetched
            }
            var all: [SportsFixture] = []
            var gotAny = false
            for index in months.indices {
                let fetched = byIndex[index] ?? []
                if !fetched.isEmpty { gotAny = true }
                all.append(contentsOf: fetched)
            }
            return (all, gotAny)
        }
    }

    /// Re-fetches the given days by day for every league and merges the fresh
    /// fixtures into each league's snapshot, leaving the rest of the month intact.
    /// A league whose every day came back empty is left untouched (that is what a
    /// failed request looks like). `fetchedAt` is left alone: it dates the last
    /// full refresh, and a live game polled all afternoon must not keep the rest
    /// of its league's schedule from ever counting as stale.
    private func refreshDays(leagueIds: [String], days: [Date]) async {
        guard !Task.isCancelled, Self.isEnabled, let provider, !days.isEmpty else { return }
        let leagues = leagueIds.compactMap { SportsCatalog.league(id: $0) }
        let fetchedByLeague = await withTaskGroup(of: (String, [SportsFixture]).self) { group in
            for league in leagues {
                for day in days {
                    group.addTask {
                        await (league.id, (try? provider.fixtures(league: league, day: day)) ?? [])
                    }
                }
            }
            var out: [String: [SportsFixture]] = [:]
            for await (leagueId, fixtures) in group {
                out[leagueId, default: []].append(contentsOf: fixtures)
            }
            return out
        }

        var updated = false
        guard !Task.isCancelled, Self.isEnabled else { return }
        for (leagueId, fetched) in fetchedByLeague {
            guard !Task.isCancelled, Self.isEnabled else { return }
            guard !fetched.isEmpty else { continue }
            var snapshot = store.snapshot(for: leagueId) ?? SportsLeagueSnapshot(fetchedAt: .distantPast)
            var byId = Dictionary(snapshot.fixtures.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for fixture in fetched {
                byId[fixture.id] = fixture
            }
            snapshot.fixtures = Array(byId.values)
            await publish(snapshot, for: leagueId)
            updated = true
        }
        if !Task.isCancelled, Self.isEnabled, updated { store.noteLiveScoreUpdate() }
    }

    // MARK: - Helpers

    /// The union of followed leagues and the leagues of followed teams, in follow
    /// order with duplicates removed.
    func leaguesToRefresh() -> [String] {
        guard Self.isEnabled else { return [] }
        var ids: [String] = []
        var seen: Set<String> = []
        for leagueId in followSource.followedLeagueIds where seen.insert(leagueId).inserted {
            ids.append(leagueId)
        }
        for teamId in followSource.followedTeamIds {
            guard let leagueId = SportsTeam.leagueID(fromTeamID: teamId) else { continue }
            if seen.insert(leagueId).inserted { ids.append(leagueId) }
        }
        return ids
    }
}

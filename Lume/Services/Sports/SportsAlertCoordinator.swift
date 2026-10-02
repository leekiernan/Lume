//
//  SportsAlertCoordinator.swift
//  Lume
//
//  Runs the in-player sports alerts while something plays: every 30 seconds it
//  fetches the scoreboards of the leagues where a followed team is on (or about
//  to be), feeds them to `SportsAlertMachine`, and queues what that raises for
//  the player's toast.
//
//  Kept apart from the Sports refresh on purpose. That one writes snapshots to
//  disk and learns crest colours on the main actor, which is why it stands
//  down during playback (main-thread work stalls KSPlayer); this feed only
//  fetches, off the main actor, and writes nothing. Channel matching runs only
//  for a game about to alert — rare, and served from the resolver's cache —
//  and decides both the channel to offer and whether the viewer is already
//  watching that game, which never alerts.
//

import Foundation
import SwiftData

/// An alert as the toast shows it.
nonisolated struct SportsAlertPresentation: Identifiable, Equatable {
    let alert: SportsAlert
    /// The channel a Play press opens; `nil` when none of the viewer's
    /// channels carries the game (the toast then only informs).
    let channel: ResolvedChannel?
    /// Hide Scores at the time it was raised, this game not revealed.
    let hidesScores: Bool

    var id: String {
        alert.id
    }
}

@MainActor
@Observable
final class SportsAlertCoordinator {
    static let shared = SportsAlertCoordinator()

    static let pollInterval: Duration = .seconds(30)
    static let displayDuration: Duration = .seconds(12)

    private(set) var presented: SportsAlertPresentation?
    /// Bumped when a Play press takes the presented alert; the player watches
    /// it and switches to `watchTarget`.
    private(set) var watchRequests = 0
    private(set) var watchTarget: SportsAlertPresentation?

    @ObservationIgnored private var queue: [SportsAlertPresentation] = []
    @ObservationIgnored private var machine = SportsAlertMachine()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var restriction = ContentRestriction()
    @ObservationIgnored private var currentMedia: PlayableMedia?
    @ObservationIgnored var provider: any SportsDataProvider = ESPNClient.shared

    // MARK: - Playback lifecycle

    func playbackBegan(media: PlayableMedia, container: ModelContainer, restriction: ContentRestriction) {
        currentMedia = media
        self.container = container
        self.restriction = restriction
        guard pollTask == nil else { return }
        pollTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func mediaChanged(_ media: PlayableMedia) {
        currentMedia = media
    }

    func playbackEnded() {
        pollTask?.cancel()
        pollTask = nil
        dismissTask?.cancel()
        queue.removeAll()
        presented = nil
        currentMedia = nil
        // A fresh machine next time: the first poll of the next session is a
        // baseline, so nothing that happened in between replays as news.
        machine = SportsAlertMachine()
    }

    // MARK: - Remote

    /// A Play press while an alert shows: take it, and ask the player to switch.
    func claimPlayPress() -> Bool {
        guard let presented, presented.channel != nil else { return false }
        watchTarget = presented
        watchRequests += 1
        dismissPresented()
        return true
    }

    func dismissPresented() {
        dismissTask?.cancel()
        presented = nil
        showNext()
    }

    // MARK: - Polling

    private var settings: SportsAlertSettings {
        SportsAlertSettings(raw: UserDefaults.standard.string(forKey: ProfileScopedPreferences.key(SportsAlertSettings.baseKey)) ?? "")
    }

    /// Whether alerts may run over what's playing now.
    private var isActive: Bool {
        guard SportsSyncService.isEnabled, PremiumManager.shared.isPremium, let currentMedia else { return false }
        switch settings.mode {
        case .off: return false
        case .liveTV: return currentMedia.isLive || currentMedia.catchup != nil
        case .everything: return true
        }
    }

    private func tick() async {
        await fireDueReminders()
        guard isActive else { return }
        let settings = settings
        let now = Date()
        let followedTeams = Set(SportsFollowService.shared.follows.filter { $0.kind == .team }.map(\.key))
        guard !followedTeams.isEmpty else { return }
        let store = SportsStore.shared
        let leagueIds = Array(Set(followedTeams.compactMap(SportsSyncService.leagueId(fromTeamID:))))
        store.loadCached(leagueIds: leagueIds)
        let candidates = Self.candidates(store.fixtures(inLeagues: leagueIds), followedTeams: followedTeams, now: now)
        guard !candidates.isEmpty else { return }

        let fetched = await Self.fetch(candidates, provider: provider)
        let followedFetched = fetched.filter { Self.involves($0, followedTeams) }
        let raised = machine.observe(followedFetched, settings: settings, watchingFixtureId: nil)
        for alert in raised {
            await enqueue(alert)
        }
    }

    /// "Remind me" games starting now: a kick-off toast while anything plays,
    /// whatever the alert settings — the viewer asked for these.
    private func fireDueReminders() async {
        guard currentMedia != nil, SportsSyncService.isEnabled, PremiumManager.shared.isPremium else { return }
        let due = SportsReminders.shared.due(now: Date())
        guard !due.isEmpty else { return }
        let probes = due.compactMap { reminder -> SportsFixture? in
            guard SportsCatalog.league(id: reminder.leagueId) != nil else { return nil }
            return SportsFixture(
                id: reminder.fixtureId, leagueId: reminder.leagueId, leagueName: "", leagueAbbreviation: "",
                startDate: reminder.start, status: SportsFixtureStatus(state: .scheduled)
            )
        }
        let now = Date()
        // A race reminder names one session ("…#Race"); the feed has weekends.
        let fetched = await Self.fetch(probes, provider: provider).flatMap { $0.expandedBySession(now: now) }
        for reminder in due {
            guard let fixture = fetched.first(where: { $0.id == reminder.fixtureId }), fixture.status.state != .scheduled else { continue }
            SportsReminders.shared.fired(reminder.fixtureId)
            await enqueue(SportsAlert(fixture: fixture, kind: .kickoff, scoringTeamId: nil))
        }
    }

    /// Followed teams' games that are on, or start within ten minutes.
    nonisolated static func candidates(
        _ fixtures: [SportsFixture],
        followedTeams: Set<String>,
        now: Date
    ) -> [SportsFixture] {
        fixtures.filter { fixture in
            involves(fixture, followedTeams)
                && fixture.startDate <= now.addingTimeInterval(600)
                && fixture.expectedEnd > now.addingTimeInterval(-600)
        }
    }

    nonisolated static func involves(_ fixture: SportsFixture, _ teams: Set<String>) -> Bool {
        if let home = fixture.home?.team.id, teams.contains(home) { return true }
        if let away = fixture.away?.team.id, teams.contains(away) { return true }
        return false
    }

    /// The candidates' leagues, each for the days their games start on.
    private nonisolated static func fetch(_ candidates: [SportsFixture], provider: any SportsDataProvider) async -> [SportsFixture] {
        var requests: Set<String> = []
        var work: [(SportsLeague, Date)] = []
        for fixture in candidates {
            guard let league = SportsCatalog.league(id: fixture.leagueId) else { continue }
            let day = Calendar.current.startOfDay(for: fixture.startDate)
            if requests.insert("\(league.id)|\(day.timeIntervalSince1970)").inserted {
                work.append((league, day))
            }
        }
        return await withTaskGroup(of: [SportsFixture].self) { group in
            for (league, day) in work {
                group.addTask { await (try? provider.fixtures(league: league, day: day)) ?? [] }
            }
            var out: [SportsFixture] = []
            for await fixtures in group {
                out.append(contentsOf: fixtures)
            }
            return out
        }
    }

    // MARK: - Queue

    private func enqueue(_ alert: SportsAlert) async {
        let channels = await channels(for: alert.fixture)
        // The viewer is watching this game (live or from its start): the
        // stream runs behind the data, so an alert would spoil it.
        if let watching = watchingStreamId, channels.contains(where: { $0.stream.id == watching }) { return }
        let hideScores = UserDefaults.standard.bool(forKey: SportsSyncService.hideScoresKey)
            && !SportsScoreReveal.shared.isRevealed(alert.fixture.id)
        queue.append(SportsAlertPresentation(alert: alert, channel: channels.first, hidesScores: hideScores))
        if presented == nil { showNext() }
    }

    private func channels(for fixture: SportsFixture) async -> [ResolvedChannel] {
        guard let container else { return [] }
        let resolved = await SportsChannelResolver.resolve(container: container, fixtures: [fixture], restriction: restriction)
        return SportsChannelPreference.ordered(resolved[fixture.id] ?? [], context: .current)
    }

    /// The live channel on screen — itself, or the channel a catch-up replays.
    private var watchingStreamId: String? {
        guard let currentMedia else { return nil }
        if let catchup = currentMedia.catchup { return catchup.streamID }
        if case let .live(id) = currentMedia.contentRef { return id }
        return nil
    }

    private func showNext() {
        guard presented == nil, !queue.isEmpty else { return }
        presented = queue.removeFirst()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.dismissPresented()
        }
    }
}

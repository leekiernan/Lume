//
//  SportsHubGrouping.swift
//  Lume
//
//  The one set of rules for which fixtures a Sports Hub scope + segment shows and
//  how they group into sections. The phone `SportsHubView` and the tvOS
//  `TVSportsHubScreen` both delegate here so the two hubs never disagree, leaving
//  each screen only its own chrome.
//

import Foundation

@MainActor
struct SportsHubGrouping {
    let scope: SportsHubScope
    let segment: SportsHubSegment
    let follows: [SportsFollow]
    let store: SportsStore
    let now: Date
    /// Followed team / league keys, built once per grouping rather than per
    /// fixture — `involvesFollowedTeam` runs for every fixture on screen.
    let followedTeamKeys: Set<String>
    let followedLeagueKeys: Set<String>

    init(
        scope: SportsHubScope,
        segment: SportsHubSegment,
        follows: [SportsFollow],
        store: SportsStore,
        now: Date = .init()
    ) {
        self.scope = scope
        self.segment = segment
        self.follows = follows
        self.store = store
        self.now = now
        followedTeamKeys = Set(follows.filter { $0.kind == .team }.map(\.key))
        followedLeagueKeys = Set(follows.filter { $0.kind == .league }.map(\.key))
    }

    /// The league ids the current scope draws from: one for a league scope, or
    /// every followed league plus the league of each followed team (deduped,
    /// order-preserving) for My Teams.
    var displayLeagueIds: [String] {
        if case let .league(id) = scope { return [id] }
        return SportsRailPlanner.displayLeagueIds(for: follows)
    }

    /// Every followed league (plus followed teams' leagues) regardless of the
    /// current scope — this feeds the scope menu, which must always offer the
    /// full list, not just the league currently selected.
    var followedLeagues: [SportsLeague] {
        Self.followedLeagues(follows)
    }

    /// The leagues the scope can narrow to, for the browse panel.
    static func followedLeagues(_ follows: [SportsFollow]) -> [SportsLeague] {
        SportsRailPlanner.displayLeagueIds(for: follows).compactMap { SportsCatalog.league(id: $0) }
    }

    var scopeIsLeague: Bool {
        if case .league = scope { return true }
        return false
    }

    func involvesFollowedTeam(_ fixture: SportsFixture) -> Bool {
        if let home = fixture.home?.team, followedTeamKeys.contains(home.id) { return true }
        if let away = fixture.away?.team, followedTeamKeys.contains(away.id) { return true }
        return false
    }

    /// Every fixture on screen for the current scope + segment, deduped and sorted
    /// by kickoff. A league followed as a league contributes all of its fixtures; a
    /// league present only through a followed team contributes just that team's.
    var visibleFixtures: [SportsFixture] {
        var byID: [String: SportsFixture] = [:]
        for leagueId in displayLeagueIds {
            guard let snapshot = store.snapshot(for: leagueId) else { continue }
            let leagueFollowed = scopeIsLeague || followedLeagueKeys.contains(leagueId)
            // A race weekend becomes one card per session before the day filter,
            // so Saturday's race shows under Saturday, not under Thursday's practice.
            for fixture in snapshot.fixtures.flatMap({ $0.expandedBySession(now: now) })
                where SportsHubView.fixture(fixture, isIn: segment, now: now)
            {
                if leagueFollowed || involvesFollowedTeam(fixture) {
                    byID[fixture.id] = fixture
                }
            }
        }
        return byID.values.sorted(by: SportsFixture.displayOrder)
    }

    /// The display groups the sections view renders, for the `visibleFixtures`
    /// the caller computed once per render. Upcoming groups by day;
    /// Today/Yesterday group by "My Teams" then followed league.
    func groups(for fixtures: [SportsFixture]) -> [SportsFixtureGroup] {
        if segment == .upcoming {
            return SportsFixtureGroup.byDay(fixtures)
        }
        // Within a section `SportsFixture.displayOrder` already puts live games
        // first, upcoming next and finished last.
        if case let .league(leagueId) = scope {
            // The header carries the crest the cards drop, same as a league
            // cluster under My Teams; no chevron, since the hub is already scoped.
            let logoURL = fixtures.first?.leagueLogoURL ?? SportsCatalog.league(id: leagueId)?.logoURL
            return fixtures.isEmpty ? [] : [SportsFixtureGroup(
                id: "all", title: scopeTitle, logoURL: logoURL, leagueId: nil, fixtures: fixtures, isSingleLeague: true
            )]
        }
        return byMyTeamsAndLeague(fixtures)
    }

    private func byMyTeamsAndLeague(_ fixtures: [SportsFixture]) -> [SportsFixtureGroup] {
        var groups: [SportsFixtureGroup] = []
        let mine = fixtures.filter(involvesFollowedTeam)
        if !mine.isEmpty {
            groups.append(SportsFixtureGroup(
                id: "myTeams",
                title: String(localized: "★ My Teams"),
                logoURL: nil,
                leagueId: nil,
                fixtures: mine
            ))
        }
        let mineIDs = Set(mine.map(\.id))
        for league in followedLeagues where followedLeagueKeys.contains(league.id) {
            let leagueFixtures = fixtures.filter { $0.leagueId == league.id && !mineIDs.contains($0.id) }
            guard !leagueFixtures.isEmpty else { continue }
            groups.append(SportsFixtureGroup(
                id: league.id,
                title: league.name,
                logoURL: leagueFixtures.first?.leagueLogoURL ?? league.logoURL,
                leagueId: league.id,
                fixtures: leagueFixtures,
                isSingleLeague: true
            ))
        }
        return groups
    }

    /// How far ahead a game can be and still headline the hub.
    static let heroHorizon: TimeInterval = 7 * 86400

    /// Hero candidates in semantic priority order. Availability is only a
    /// tie-break within each tier: a lower-tier highlight cannot replace a live
    /// game simply because its guide match arrived first. Within a tier the
    /// bigger game leads (`SportsHighlights.evaluate`), and among the wider
    /// upcoming games today's lead the week's — they're what the carousel
    /// pages through after its headline.
    func heroCandidates(
        in fixtures: [SportsFixture],
        highlights: [SportsFixture] = [],
        availableIDs: Set<String> = []
    ) -> [SportsHeroSelectionMachine.Candidate] {
        guard segment != .yesterday else { return [] }
        let live = byStature(fixtures.filter(\.isInProgress))
        let upcoming = upcomingFixtures(alongside: fixtures)
        var candidates: [SportsHeroSelectionMachine.Candidate] = []
        var seen: Set<String> = []

        func append(_ fixtures: [SportsFixture], tier: SportsHeroSelectionMachine.Tier) {
            for fixture in fixtures where seen.insert(fixture.id).inserted {
                candidates.append(SportsHeroSelectionMachine.Candidate(
                    fixture: fixture, tier: tier, isAvailable: availableIDs.contains(fixture.id)
                ))
            }
        }

        append(live.filter(involvesFollowedTeam), tier: .followedLive)
        append(live.filter { !involvesFollowedTeam($0) }, tier: .live)
        if scopeIsLeague {
            append(upcoming, tier: .primaryUpcoming)
        } else {
            append(upcoming.filter(involvesFollowedTeam), tier: .primaryUpcoming)
        }
        for highlight in highlights {
            let tier: SportsHeroSelectionMachine.Tier = if highlight.isInProgress {
                involvesFollowedTeam(highlight) ? .followedLive : .live
            } else {
                .highlight
            }
            append([highlight], tier: tier)
        }
        if !scopeIsLeague {
            let others = upcoming.filter { !involvesFollowedTeam($0) }
            let calendar = Calendar.current
            let today = others.filter { calendar.isDate($0.headlineDate, inSameDayAs: now) }
            append(byStature(today), tier: .contextualUpcoming)
            append(others, tier: .contextualUpcoming)
        }
        return candidates
    }

    /// Bigger games first — a heavyweight international before a minnows'
    /// qualifier — keeping kickoff order between equals.
    private func byStature(_ fixtures: [SportsFixture]) -> [SportsFixture] {
        let scores = Dictionary(uniqueKeysWithValues: fixtures.map { fixture in
            (fixture.id, SportsHighlights.evaluate(fixture, table: store.snapshot(for: fixture.leagueId)?.standings ?? []).0)
        })
        return fixtures.enumerated()
            .sorted { lhs, rhs in
                let left = scores[lhs.element.id] ?? 0
                let right = scores[rhs.element.id] ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The scope's games in the week ahead, soonest first — what's on screen
    /// plus the rest of the cached schedule, practice sessions left out.
    private func upcomingFixtures(alongside fixtures: [SportsFixture]) -> [SportsFixture] {
        var byID: [String: SportsFixture] = [:]
        let cached = displayLeagueIds
            .compactMap { store.snapshot(for: $0) }
            .flatMap { snapshot in snapshot.fixtures.flatMap { $0.expandedBySession(now: now) } }
        for fixture in fixtures + cached {
            guard fixture.status.state == .scheduled, fixture.headlineDate >= now,
                  fixture.headlineDate.timeIntervalSince(now) <= Self.heroHorizon,
                  ![.fp1, .fp2, .fp3].contains(fixture.sessionKind),
                  scopeIsLeague || followedLeagueKeys.contains(fixture.leagueId) || involvesFollowedTeam(fixture)
            else { continue }
            byID[fixture.id] = fixture
        }
        return byID.values.sorted { $0.headlineDate < $1.headlineDate }
    }

    var scopeTitle: String {
        switch scope {
        case .myTeams:
            String(localized: "My Teams")
        case let .league(id):
            SportsCatalog.league(id: id)?.name ?? String(localized: "My Teams")
        }
    }
}

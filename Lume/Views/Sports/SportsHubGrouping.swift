//
//  SportsHubGrouping.swift
//  Lume
//
//  The one set of rules for which fixtures the Sports Hub shows and how they
//  form rows. The phone `SportsHubView` and the tvOS `TVSportsHubScreen` both
//  delegate here so the two hubs never disagree, leaving each screen only its
//  own chrome.
//
//  There is no day switch: the hub is what's live and what's coming in the
//  next fortnight, never results. Unscoped, that's a Live Now row then one row
//  per follow in the viewer's own order (Manage Teams) — Chelsea FC above F1
//  above the Premier League, as they like. Scoped to one follow from the
//  sidebar, it's that team's or league's games alone.
//

import Foundation

/// What the hub shows: everything followed, or one follow — a team or a
/// league today, a driver or a player once those can be followed.
enum SportsHubScope: Hashable {
    case all
    case follow(String)
}

/// A follow's own page, pushed from the browse panel or a row's header — the
/// way Movies pushes a category's grid rather than filtering its landing page.
struct SportsFollowRoute: Hashable {
    let key: String
}

@MainActor
struct SportsHubGrouping {
    let scope: SportsHubScope
    let follows: [SportsFollow]
    let store: SportsStore
    let now: Date
    /// Followed team / league keys, built once per grouping rather than per
    /// fixture — `involvesFollowedTeam` runs for every fixture on screen.
    let followedTeamKeys: Set<String>
    let followedLeagueKeys: Set<String>
    /// Follows the viewer took off the hub (Settings ▸ Sports): no row of
    /// their own, and nothing on the page only because of them.
    let hiddenKeys: Set<String>

    /// How far ahead the hub's rows reach.
    static let horizon: TimeInterval = 14 * 86400

    init(
        scope: SportsHubScope,
        follows: [SportsFollow],
        store: SportsStore,
        hiddenKeys: Set<String> = [],
        now: Date = .init()
    ) {
        self.scope = scope
        self.follows = follows
        self.store = store
        self.hiddenKeys = hiddenKeys
        self.now = now
        followedTeamKeys = Set(follows.filter { $0.kind == .team }.map(\.key))
        followedLeagueKeys = Set(follows.filter { $0.kind == .league }.map(\.key))
    }

    // MARK: - Scope

    /// The follow the hub is narrowed to, if any.
    var scopedFollow: SportsFollow? {
        guard case let .follow(key) = scope else { return nil }
        return follows.first { $0.key == key }
            ?? SportsFollow(key: key, kind: SportsCatalog.league(id: key) == nil ? .team : .league, sortOrder: 0)
    }

    var isScoped: Bool {
        scopedFollow != nil
    }

    /// The team the hub is narrowed to — what its club section shows.
    var scopedTeam: SportsTeam? {
        guard let follow = scopedFollow, follow.kind == .team else { return nil }
        return store.team(by: follow.key)
    }

    /// The league ids the hub draws from: the scoped league or team's league,
    /// else every followed league plus each followed team's.
    var displayLeagueIds: [String] {
        switch scopedFollow?.kind {
        case .league: [scopedFollow?.key].compactMap(\.self)
        case .team: [scopedFollow.map { Self.leagueId(ofTeam: $0.key) }].compactMap(\.self)
        case nil: SportsRailPlanner.displayLeagueIds(for: follows)
        }
    }

    /// "espn:soccer/eng.1:363" → "espn:soccer/eng.1".
    static func leagueId(ofTeam key: String) -> String {
        key.range(of: ":", options: .backwards).map { String(key[..<$0.lowerBound]) } ?? key
    }

    /// Every followed league (plus followed teams' leagues), for the sidebar.
    var followedLeagues: [SportsLeague] {
        Self.followedLeagues(follows)
    }

    static func followedLeagues(_ follows: [SportsFollow]) -> [SportsLeague] {
        SportsRailPlanner.displayLeagueIds(for: follows).compactMap { SportsCatalog.league(id: $0) }
    }

    func involvesFollowedTeam(_ fixture: SportsFixture) -> Bool {
        if let home = fixture.home?.team, followedTeamKeys.contains(home.id) { return true }
        if let away = fixture.away?.team, followedTeamKeys.contains(away.id) { return true }
        return false
    }

    private func involves(_ fixture: SportsFixture, team key: String) -> Bool {
        fixture.home?.team.id == key || fixture.away?.team.id == key
    }

    // MARK: - Fixtures

    /// Live now, or due within `horizon` — never a result.
    func isCurrent(_ fixture: SportsFixture) -> Bool {
        if fixture.isInProgress { return true }
        return fixture.status.state == .scheduled && fixture.expectedEnd > now
            && fixture.headlineDate.timeIntervalSince(now) <= Self.horizon
    }

    /// Every fixture the hub shows, deduped, live first then by kickoff. A
    /// league followed as a league contributes all its fixtures; one present
    /// only through a followed team, just that team's.
    var visibleFixtures: [SportsFixture] {
        var byID: [String: SportsFixture] = [:]
        for leagueId in displayLeagueIds {
            guard let snapshot = store.snapshot(for: leagueId) else { continue }
            // A race weekend becomes one card per session, so Saturday's race
            // is its own card, not under Thursday's practice.
            for fixture in snapshot.fixtures.flatMap({ $0.expandedBySession(now: now) }) where isCurrent(fixture) {
                if isInScope(fixture) { byID[fixture.id] = fixture }
            }
        }
        return byID.values.sorted(by: SportsFixture.displayOrder)
    }

    private func isInScope(_ fixture: SportsFixture) -> Bool {
        switch scopedFollow?.kind {
        case .league: true
        case .team: scopedFollow.map { involves(fixture, team: $0.key) } ?? false
        case nil:
            (followedLeagueKeys.contains(fixture.leagueId) && !hiddenKeys.contains(fixture.leagueId))
                || [fixture.home?.team.id, fixture.away?.team.id].contains { key in
                    key.map { followedTeamKeys.contains($0) && !hiddenKeys.contains($0) } ?? false
                }
        }
    }

    // MARK: - Rows

    /// The hub's rows for the `visibleFixtures` the caller computed once per
    /// render. Unscoped: Live Now, then a row per follow in the viewer's order,
    /// each game in the first row that claims it. Scoped: one row.
    func groups(for fixtures: [SportsFixture]) -> [SportsFixtureGroup] {
        guard !fixtures.isEmpty else { return [] }
        if let follow = scopedFollow {
            return [SportsFixtureGroup(
                id: "scope", title: scopeTitle, logoURL: logoURL(of: follow, in: fixtures), leagueId: nil,
                fixtures: fixtures, isSingleLeague: follow.kind == .league
            )]
        }
        var groups: [SportsFixtureGroup] = []
        let live = fixtures.filter(\.isInProgress)
        if !live.isEmpty {
            groups.append(SportsFixtureGroup(id: "live", title: String(localized: "Live now"), logoURL: nil, leagueId: nil, fixtures: live))
        }
        var claimed = Set(live.map(\.id))
        for follow in follows where !hiddenKeys.contains(follow.key) {
            let rowFixtures = fixtures.filter { fixture in
                guard !claimed.contains(fixture.id) else { return false }
                return follow.kind == .team ? involves(fixture, team: follow.key) : fixture.leagueId == follow.key
            }
            guard !rowFixtures.isEmpty else { continue }
            claimed.formUnion(rowFixtures.map(\.id))
            groups.append(SportsFixtureGroup(
                id: follow.key,
                title: title(of: follow),
                logoURL: logoURL(of: follow, in: rowFixtures),
                leagueId: follow.kind == .league ? follow.key : nil,
                fixtures: rowFixtures,
                isSingleLeague: follow.kind == .league,
                followKey: follow.key
            ))
        }
        return groups
    }

    /// The sidebar's rows: every follow — teams and leagues alike — in the
    /// viewer's order, named and badged as the rows are.
    var sidebarEntries: [SportsBrowseSidebar.Entry] {
        follows.map { follow in
            SportsBrowseSidebar.Entry(key: follow.key, title: title(of: follow), logoURL: logoURL(of: follow, in: []))
        }
    }

    private func title(of follow: SportsFollow) -> String {
        switch follow.kind {
        case .league: SportsCatalog.league(id: follow.key)?.name ?? follow.key
        case .team: store.team(by: follow.key)?.name ?? follow.key
        }
    }

    private func logoURL(of follow: SportsFollow, in fixtures: [SportsFixture]) -> URL? {
        switch follow.kind {
        case .league: fixtures.first?.leagueLogoURL ?? SportsCatalog.league(id: follow.key)?.logoURL
        case .team: store.team(by: follow.key)?.logoURL
        }
    }

    // MARK: - Hero

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
        if isScoped {
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
        if !isScoped {
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
                  isInScope(fixture)
            else { continue }
            byID[fixture.id] = fixture
        }
        return byID.values.sorted { $0.headlineDate < $1.headlineDate }
    }

    var scopeTitle: String {
        guard let follow = scopedFollow else { return String(localized: "My Sports") }
        return title(of: follow)
    }
}

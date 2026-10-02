//
//  SportsHubHeroTests.swift
//  LumeTests
//
//  Which game the hub headlines: semantic tiers keep live/followed fixtures
//  ahead of wider highlights, while channel availability chooses within a
//  tier. Yesterday has none.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsHubHeroTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let leagueId = "espn:soccer/eng.1"

    private func grouping(scope: SportsHubScope = .all) -> SportsHubGrouping {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return SportsHubGrouping(
            scope: scope,
            follows: [
                SportsFollow(key: leagueId, kind: .league, sortOrder: 0),
                SportsFollow(key: "\(leagueId):1", kind: .team, sortOrder: 1)
            ],
            store: SportsStore(cache: SportsCacheStore(directory: dir)),
            now: now
        )
    }

    private func game(_ id: String, home: String, away: String, offset: TimeInterval, state: SportsFixtureState) -> SportsFixture {
        func team(_ teamId: String) -> SportsCompetitor {
            SportsCompetitor(team: SportsTeam(leagueId: leagueId, teamId: teamId, name: teamId, shortName: teamId, abbreviation: teamId))
        }
        return SportsFixture(
            id: id, leagueId: leagueId, leagueName: "Premier League", leagueAbbreviation: "EPL",
            startDate: now.addingTimeInterval(offset), status: SportsFixtureStatus(state: state),
            home: team(home), away: team(away)
        )
    }

    private func hero(
        _ fixtures: [SportsFixture],
        fallback: SportsFixture? = nil,
        availableIDs: Set<String> = []
    ) -> SportsFixture? {
        let grouping = grouping()
        let candidates = grouping.heroCandidates(in: fixtures, highlights: fallback.map { [$0] } ?? [], availableIDs: availableIDs)
        var machine = SportsHeroSelectionMachine()
        machine.reconcile(candidates: candidates, context: "test")
        return machine.displayed(in: candidates, context: "test")?.fixture
    }

    @Test func `a followed team's live game leads`() {
        let other = game("other", home: "5", away: "6", offset: -1800, state: .inProgress)
        let mine = game("mine", home: "1", away: "2", offset: -600, state: .inProgress)

        #expect(hero([other, mine])?.id == "mine")
    }

    @Test func `any live game in a followed league leads when the team isn't playing`() {
        let other = game("other", home: "5", away: "6", offset: -1800, state: .inProgress)
        let later = game("later", home: "1", away: "2", offset: 3600, state: .scheduled)

        #expect(hero([later, other])?.id == "other")
    }

    @Test func `with nothing live, the followed team's next game`() {
        let soon = game("soon", home: "1", away: "2", offset: 3 * 3600, state: .scheduled)
        let leagueOnly = game("league", home: "5", away: "6", offset: 3600, state: .scheduled)

        #expect(hero([leagueOnly, soon])?.id == "soon")
    }

    @Test func `the followed team's game later in the week still headlines`() {
        let thursday = game("thursday", home: "1", away: "2", offset: 4 * 86400, state: .scheduled)
        let done = game("done", home: "1", away: "2", offset: -4 * 3600, state: .final)

        #expect(hero([thursday, done])?.id == "thursday")
    }

    @Test func `with no followed game, the biggest pick of the week`() {
        let leagueOnly = game("league", home: "5", away: "6", offset: 3600, state: .scheduled)
        let big = game("big", home: "7", away: "8", offset: 2 * 86400, state: .scheduled)

        #expect(hero([leagueOnly], fallback: big)?.id == "big")
    }

    @Test func `with no pick either, the followed leagues' next game`() {
        let leagueOnly = game("league", home: "5", away: "6", offset: 3600, state: .scheduled)

        #expect(hero([leagueOnly])?.id == "league")
    }

    @Test func `channel availability keeps the followed upcoming tier ahead of a fallback`() {
        let mine = game("mine", home: "1", away: "2", offset: 3600, state: .scheduled)
        let big = game("big", home: "7", away: "8", offset: 2 * 86400, state: .scheduled)

        #expect(hero([mine], fallback: big, availableIDs: ["mine"])?.id == "mine")
    }

    @Test func `a lower-tier on-channel fallback cannot displace a followed game`() {
        let mine = game("mine", home: "1", away: "2", offset: 3600, state: .scheduled)
        let big = game("big", home: "7", away: "8", offset: 2 * 86400, state: .scheduled)

        #expect(hero([mine], fallback: big, availableIDs: ["big"])?.id == "mine")
    }

    @Test func `the followed upcoming game remains the remind-me hero without a channel`() {
        let mine = game("mine", home: "1", away: "2", offset: 3600, state: .scheduled)
        let big = game("big", home: "7", away: "8", offset: 2 * 86400, state: .scheduled)

        #expect(hero([mine], fallback: big)?.id == "mine")
    }

    @Test func `beyond a week, nothing headlines`() {
        let far = game("far", home: "1", away: "2", offset: 9 * 86400, state: .scheduled)

        #expect(hero([far]) == nil)
    }

    // MARK: - Rows

    @Test func `live games lead, then a row per follow in the viewer's order`() {
        let live = game("live", home: "5", away: "6", offset: -600, state: .inProgress)
        let mine = game("mine", home: "1", away: "2", offset: 3600, state: .scheduled)
        let league = game("league", home: "5", away: "6", offset: 7200, state: .scheduled)

        let groups = grouping().groups(for: [live, mine, league])
        // The league is followed first here, so its row claims the team's game
        // too, and the team's own row has nothing left to show.
        #expect(groups.map(\.id) == ["live", leagueId])
        #expect(groups.map { $0.fixtures.map(\.id) } == [["live"], ["mine", "league"]])
    }

    @Test func `a team followed first gets its games before its league's row`() {
        let follows = [
            SportsFollow(key: "\(leagueId):1", kind: .team, sortOrder: 0),
            SportsFollow(key: leagueId, kind: .league, sortOrder: 1)
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let grouping = SportsHubGrouping(
            scope: .all, follows: follows, store: SportsStore(cache: SportsCacheStore(directory: dir)), now: now
        )
        let mine = game("mine", home: "1", away: "2", offset: 3600, state: .scheduled)
        let league = game("league", home: "5", away: "6", offset: 7200, state: .scheduled)

        let groups = grouping.groups(for: [mine, league])
        #expect(groups.map(\.id) == ["\(leagueId):1", leagueId])
        #expect(groups.map { $0.fixtures.map(\.id) } == [["mine"], ["league"]])
        #expect(groups.first?.followKey == "\(leagueId):1")
    }

    @Test func `the hub shows what's live and coming, never results`() {
        let grouping = grouping()
        #expect(grouping.isCurrent(game("live", home: "1", away: "2", offset: -600, state: .inProgress)))
        #expect(grouping.isCurrent(game("soon", home: "1", away: "2", offset: 86400, state: .scheduled)))
        #expect(!grouping.isCurrent(game("done", home: "1", away: "2", offset: -4 * 3600, state: .final)))
        #expect(!grouping.isCurrent(game("far", home: "1", away: "2", offset: 20 * 86400, state: .scheduled)))
    }

    @Test func `narrowed to a team, the page is that team's games`() {
        let grouping = grouping(scope: .follow("\(leagueId):1"))
        #expect(grouping.displayLeagueIds == [leagueId])
        let mine = game("mine", home: "1", away: "2", offset: 3600, state: .scheduled)
        #expect(grouping.groups(for: [mine]).map(\.id) == ["scope"])
    }

    @Test func `the carousel pages through today's games, the bigger first`() {
        let minnows = game("minnows", home: "5", away: "6", offset: 2 * 3600, state: .scheduled)
        let derby = game("derby", home: "Arsenal", away: "Tottenham Hotspur", offset: 4 * 3600, state: .scheduled)
        let later = game("later", home: "7", away: "8", offset: 3 * 86400, state: .scheduled)

        let ids = grouping().heroCandidates(in: [minnows, derby, later]).map(\.id)
        #expect(ids == ["derby", "minnows", "later"])
    }

    @Test func `every Big This Week pick can be a slide`() {
        let first = game("first", home: "7", away: "8", offset: 2 * 86400, state: .scheduled)
        let second = game("second", home: "9", away: "10", offset: 3 * 86400, state: .scheduled)

        let ids = grouping().heroCandidates(in: [], highlights: [first, second]).map(\.id)
        #expect(ids.starts(with: ["first", "second"]))
    }
}

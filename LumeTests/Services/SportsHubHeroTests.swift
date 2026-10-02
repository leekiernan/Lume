//
//  SportsHubHeroTests.swift
//  LumeTests
//
//  Which game the hub headlines: a followed team's live game, else any live
//  game the viewer follows, else the followed team's next game this week, else
//  the biggest "Big this week" pick, else the followed leagues' next game.
//  Yesterday has none.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsHubHeroTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let leagueId = "espn:soccer/eng.1"

    private func grouping(segment: SportsHubSegment = .today) -> SportsHubGrouping {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return SportsHubGrouping(
            scope: .myTeams,
            segment: segment,
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

    @Test func `a followed team's live game leads`() {
        let other = game("other", home: "5", away: "6", offset: -1800, state: .inProgress)
        let mine = game("mine", home: "1", away: "2", offset: -600, state: .inProgress)

        #expect(grouping().heroFixture(in: [other, mine])?.id == "mine")
    }

    @Test func `any live game in a followed league leads when the team isn't playing`() {
        let other = game("other", home: "5", away: "6", offset: -1800, state: .inProgress)
        let later = game("later", home: "1", away: "2", offset: 3600, state: .scheduled)

        #expect(grouping().heroFixture(in: [later, other])?.id == "other")
    }

    @Test func `with nothing live, the followed team's next game`() {
        let soon = game("soon", home: "1", away: "2", offset: 3 * 3600, state: .scheduled)
        let leagueOnly = game("league", home: "5", away: "6", offset: 3600, state: .scheduled)

        #expect(grouping().heroFixture(in: [leagueOnly, soon])?.id == "soon")
    }

    @Test func `the followed team's game later in the week still headlines`() {
        let thursday = game("thursday", home: "1", away: "2", offset: 4 * 86400, state: .scheduled)
        let done = game("done", home: "1", away: "2", offset: -4 * 3600, state: .final)

        #expect(grouping().heroFixture(in: [thursday, done])?.id == "thursday")
    }

    @Test func `with no followed game, the biggest pick of the week`() {
        let leagueOnly = game("league", home: "5", away: "6", offset: 3600, state: .scheduled)
        let big = game("big", home: "7", away: "8", offset: 2 * 86400, state: .scheduled)

        #expect(grouping().heroFixture(in: [leagueOnly], fallback: big)?.id == "big")
    }

    @Test func `with no pick either, the followed leagues' next game`() {
        let leagueOnly = game("league", home: "5", away: "6", offset: 3600, state: .scheduled)

        #expect(grouping().heroFixture(in: [leagueOnly])?.id == "league")
    }

    @Test func `beyond a week, nothing headlines`() {
        let far = game("far", home: "1", away: "2", offset: 9 * 86400, state: .scheduled)

        #expect(grouping().heroFixture(in: [far]) == nil)
    }

    @Test func `yesterday has no hero`() {
        let mine = game("mine", home: "1", away: "2", offset: -600, state: .inProgress)

        #expect(grouping(segment: .yesterday).heroFixture(in: [mine]) == nil)
    }
}

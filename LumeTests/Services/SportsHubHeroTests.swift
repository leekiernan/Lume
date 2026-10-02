//
//  SportsHubHeroTests.swift
//  LumeTests
//
//  Which game the hub headlines on Today: a followed team's live game, else
//  any live game the viewer follows, else a followed team's game starting soon.
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

    @Test func `with nothing live, the followed team's next game within twelve hours`() {
        let soon = game("soon", home: "1", away: "2", offset: 3 * 3600, state: .scheduled)
        let leagueOnly = game("league", home: "5", away: "6", offset: 3600, state: .scheduled)

        #expect(grouping().heroFixture(in: [leagueOnly, soon])?.id == "soon")
    }

    @Test func `nothing qualifies, no hero`() {
        let tomorrow = game("tomorrow", home: "1", away: "2", offset: 20 * 3600, state: .scheduled)
        let done = game("done", home: "1", away: "2", offset: -4 * 3600, state: .final)

        #expect(grouping().heroFixture(in: [tomorrow, done]) == nil)
    }

    @Test func `only today has a hero`() {
        let mine = game("mine", home: "1", away: "2", offset: -600, state: .inProgress)

        #expect(grouping(segment: .upcoming).heroFixture(in: [mine]) == nil)
    }
}

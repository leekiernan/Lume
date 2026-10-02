//
//  SportsHighlightsTests.swift
//  LumeTests
//
//  "Big this week": finals, numbered UFC cards, table clashes and derbies rise;
//  an ordinary game doesn't make it; followed teams are left to their own
//  rail; no sport takes more than two places.
//

import Foundation
@testable import Lume
import Testing

struct SportsHighlightsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func game(
        _ id: String,
        league: String = "espn:soccer/eng.1",
        home: String = "Home",
        away: String = "Away",
        homeId: String = "1",
        awayId: String = "2",
        stage: String? = nil,
        name: String? = nil,
        offset: TimeInterval = 86400
    ) -> SportsFixture {
        func team(_ teamName: String, _ teamId: String) -> SportsCompetitor {
            SportsCompetitor(team: SportsTeam(leagueId: league, teamId: teamId, name: teamName, shortName: teamName, abbreviation: ""))
        }
        return SportsFixture(
            id: id, leagueId: league, leagueName: "", leagueAbbreviation: "",
            startDate: now.addingTimeInterval(offset), status: SportsFixtureStatus(state: .scheduled),
            home: name == nil ? team(home, homeId) : nil, away: name == nil ? team(away, awayId) : nil,
            name: name, stage: stage
        )
    }

    private func rank(_ fixtures: [SportsFixture], standings: [String: [SportsStandingRow]] = [:], followed: Set<String> = []) -> [SportsHighlight] {
        SportsHighlights.rank(fixtures, standings: standings, followedTeamIds: followed, availableIds: [], now: now)
    }

    @Test func `a cup final leads, named as a final`() {
        let final = game("final", league: "espn:soccer/eng.fa", stage: "final")
        let ordinary = game("ordinary")
        let picked = rank([ordinary, final])

        #expect(picked.map(\.id) == ["final"])
        #expect(picked.first?.reason == .final)
    }

    @Test func `a numbered UFC card makes it, a fight night doesn't`() {
        let numbered = game("ufc332", league: "espn:mma/ufc", name: "UFC 332: Silva vs. Wang")
        let fightNight = game("fn", league: "espn:mma/ufc", name: "UFC Fight Night: A vs. B")
        let picked = rank([numbered, fightNight])

        #expect(picked.map(\.id) == ["ufc332"])
        #expect(picked.first?.reason == .numberedCard)
    }

    @Test func `top-of-the-table and derbies rise`() {
        let table = [
            SportsStandingRow(id: "1", teamId: "1", name: "Liverpool", rank: 1),
            SportsStandingRow(id: "3", teamId: "3", name: "Man City", rank: 3)
        ]
        let clash = game("clash", homeId: "1", awayId: "3")
        let derby = game("derby", home: "Real Madrid", away: "Barcelona", homeId: "8", awayId: "9", offset: 2 * 86400)
        let picked = rank([clash, derby], standings: ["espn:soccer/eng.1": table])

        #expect(Set(picked.map(\.id)) == ["clash", "derby"])
        #expect(picked.first { $0.id == "clash" }?.reason == .tableClash(1, 3))
        #expect(picked.first { $0.id == "derby" }?.reason == .derby)
    }

    @Test func `a followed team's game is left to its own rail`() {
        let final = game("final", league: "espn:soccer/eng.fa", homeId: "1", stage: "final")
        let picked = rank([final], followed: ["espn:soccer/eng.fa:1"])
        #expect(picked.isEmpty)
    }

    @Test func `no sport takes more than two places`() {
        let finals = (1 ... 4).map { game("f\($0)", league: "espn:soccer/eng.fa", homeId: "h\($0)", awayId: "a\($0)", stage: "final") }
        let card = game("ufc", league: "espn:mma/ufc", name: "UFC 333: X vs. Y")
        let picked = rank(finals + [card])

        #expect(picked.count(where: { $0.fixture.sport == "soccer" }) == 2)
        #expect(picked.contains { $0.id == "ufc" })
    }

    @Test func `past and far-off games are left out`() {
        let past = game("past", league: "espn:soccer/eng.fa", stage: "final", offset: -86400)
        let far = game("far", league: "espn:soccer/eng.fa", stage: "final", offset: 10 * 86400)
        #expect(rank([past, far]).isEmpty)
    }

    @Test func `a fight card remains upcoming until its main card`() {
        let card = SportsFixture(
            id: "ufc", leagueId: "espn:mma/ufc", leagueName: "UFC", leagueAbbreviation: "UFC",
            startDate: now.addingTimeInterval(-2 * 3600), status: SportsFixtureStatus(state: .scheduled),
            name: "UFC 332: Silva vs. Wang", mainCardDate: now.addingTimeInterval(2 * 3600)
        )

        #expect(rank([card]).map(\.id) == ["ufc"])
    }
}

struct SportsHeavyweightsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func international(_ home: String, _ away: String, league: String = "espn:soccer/fifa.worldq.uefa") -> SportsFixture {
        func team(_ name: String) -> SportsCompetitor {
            SportsCompetitor(team: SportsTeam(leagueId: league, teamId: name, name: name, shortName: name, abbreviation: ""))
        }
        return SportsFixture(
            id: "\(home)-\(away)", leagueId: league, leagueName: "", leagueAbbreviation: "",
            startDate: now.addingTimeInterval(3600), status: SportsFixtureStatus(state: .scheduled),
            home: team(home), away: team(away)
        )
    }

    @Test func `a France v Italy qualifier is big this week`() {
        let picked = SportsHighlights.rank(
            [international("France", "Italy"), international("Kazakhstan", "Moldova")],
            standings: [:], followedTeamIds: [], availableIds: [], now: now
        )
        #expect(picked.map(\.id) == ["France-Italy"])
        #expect(picked.first?.reason == .heavyweights)
    }
}

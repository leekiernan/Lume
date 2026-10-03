//
//  SportsAlertMachineTests.swift
//  LumeTests
//
//  Which alerts a run of polls raises: never on the first sighting, once per
//  event, never for the game on screen, and only the events a sport is set to.
//

import Foundation
@testable import Lume
import Testing

struct SportsAlertMachineTests {
    private let kickoff = Date(timeIntervalSince1970: 1_800_000_000)
    private let settings = SportsAlertSettings(mode: .everything)

    private func game(
        _ id: String = "g1",
        sport: String = "soccer",
        state: SportsFixtureState,
        home: Int? = nil,
        away: Int? = nil,
        typeName: String? = nil
    ) -> SportsFixture {
        let league = "espn:\(sport)/test"
        func side(_ teamId: String, _ score: Int?) -> SportsCompetitor {
            SportsCompetitor(
                team: SportsTeam(leagueId: league, teamId: teamId, name: teamId, shortName: teamId, abbreviation: teamId),
                score: score
            )
        }
        return SportsFixture(
            id: id, leagueId: league, leagueName: "Test", leagueAbbreviation: "T",
            startDate: kickoff, status: SportsFixtureStatus(state: state, typeName: typeName),
            home: side("h", home), away: side("a", away)
        )
    }

    @Test func `the first sighting raises nothing`() {
        var machine = SportsAlertMachine()
        let alerts = machine.observe([game(state: .inProgress, home: 2, away: 1)], settings: settings, watchingFixtureId: nil)
        #expect(alerts.isEmpty)
    }

    @Test func `a goal raises one alert naming the scorer, once`() {
        var machine = SportsAlertMachine()
        _ = machine.observe([game(state: .inProgress, home: 0, away: 0)], settings: settings, watchingFixtureId: nil)
        let goal = machine.observe([game(state: .inProgress, home: 1, away: 0)], settings: settings, watchingFixtureId: nil)
        let again = machine.observe([game(state: .inProgress, home: 1, away: 0)], settings: settings, watchingFixtureId: nil)

        #expect(goal.map(\.kind) == [.score])
        #expect(goal.first?.scoringTeamId == "espn:soccer/test:h")
        #expect(again.isEmpty)
    }

    @Test func `the game on screen never alerts, and switching away doesn't replay it`() {
        var machine = SportsAlertMachine()
        _ = machine.observe([game(state: .inProgress, home: 0, away: 0)], settings: settings, watchingFixtureId: nil)
        let whileWatching = machine.observe([game(state: .inProgress, home: 1, away: 0)], settings: settings, watchingFixtureId: "g1")
        let afterSwitching = machine.observe([game(state: .inProgress, home: 1, away: 0)], settings: settings, watchingFixtureId: nil)

        #expect(whileWatching.isEmpty)
        #expect(afterSwitching.isEmpty)
    }

    @Test func `kick-off, half-time and the final whistle are their own events`() {
        var custom = SportsAlertSettings(mode: .everything)
        custom.set(.kickoff, true, sport: "soccer")
        custom.set(.halfTime, true, sport: "soccer")
        var machine = SportsAlertMachine()

        _ = machine.observe([game(state: .scheduled)], settings: custom, watchingFixtureId: nil)
        let started = machine.observe([game(state: .inProgress, home: 0, away: 0)], settings: custom, watchingFixtureId: nil)
        let halfTime = machine.observe(
            [game(state: .inProgress, home: 0, away: 0, typeName: "STATUS_HALFTIME")], settings: custom, watchingFixtureId: nil
        )
        let ended = machine.observe([game(state: .final, home: 0, away: 0)], settings: custom, watchingFixtureId: nil)

        #expect(started.map(\.kind) == [.kickoff])
        #expect(halfTime.map(\.kind) == [.halfTime])
        #expect(ended.map(\.kind) == [.finalResult])
    }

    @Test func `basketball baskets don't alert by default, the result does`() {
        var machine = SportsAlertMachine()
        _ = machine.observe([game(sport: "basketball", state: .inProgress, home: 50, away: 48)], settings: settings, watchingFixtureId: nil)
        let basket = machine.observe([game(sport: "basketball", state: .inProgress, home: 52, away: 48)], settings: settings, watchingFixtureId: nil)
        let result = machine.observe([game(sport: "basketball", state: .final, home: 101, away: 99)], settings: settings, watchingFixtureId: nil)

        #expect(basket.isEmpty)
        #expect(result.map(\.kind) == [.finalResult])
    }

    @Test func `settings round-trip through their stored string`() {
        var stored = SportsAlertSettings(mode: .liveTV)
        stored.set(.score, false, sport: "soccer")
        let restored = SportsAlertSettings(raw: stored.raw)

        #expect(restored == stored)
        #expect(!restored.alerts(.score, sport: "soccer"))
        #expect(SportsAlertSettings(raw: "nonsense").mode == .off)
    }
}

//
//  SportsTeamSeasonTests.swift
//  LumeTests
//
//  A team's season: ESPN's team schedule decodes (scores as objects, status
//  on the competition, the round on the event), and each competition becomes
//  the card its format calls for — table, league phase with bands, or the
//  cup path — for this season only.
//

import Foundation
@testable import Lume
import Testing

struct SportsTeamSeasonTests {
    private let now = Date(timeIntervalSince1970: 1_790_900_000) // early October 2026
    private let league = SportsLeague(sport: "soccer", slug: "eng.league_cup", name: "Carabao Cup", abbreviation: "EFL", region: .ukAndIreland)

    /// Trimmed from ESPN's `teams/359/schedule` for the League Cup.
    private let scheduleJSON = """
    {"events": [{"id": "401914268", "date": "2026-09-15T19:00Z", "name": "Arsenal at Ipswich Town",
      "seasonType": {"name": "Third Round"},
      "competitions": [{"date": "2026-09-15T19:00Z",
        "status": {"type": {"name": "STATUS_FULL_TIME", "state": "post", "completed": true, "detail": "FT", "shortDetail": "FT"}},
        "competitors": [
          {"homeAway": "home", "winner": false, "score": {"value": 2.0, "displayValue": "2"},
           "team": {"id": "373", "displayName": "Ipswich Town", "shortDisplayName": "Ipswich", "abbreviation": "IPS"}},
          {"homeAway": "away", "winner": true, "score": {"value": 4.0, "displayValue": "4"},
           "team": {"id": "359", "displayName": "Arsenal", "shortDisplayName": "Arsenal", "abbreviation": "ARS"}}]}]}]}
    """

    private func scheduleFixtures() throws -> [SportsFixture] {
        let scoreboard = try JSONDecoder().decode(ESPNScoreboard.self, from: Data(scheduleJSON.utf8))
        let rounds = Dictionary(uniqueKeysWithValues: (scoreboard.events ?? []).compactMap { event in
            event.id.map { ($0, event.seasonType?.name) }
        })
        return ESPNClient.mapScoreboard(scoreboard, league: league).map { $0.withRound(rounds[$0.id] ?? nil) }
    }

    @Test func `a team schedule decodes its scores, status and round`() throws {
        let game = try #require(try scheduleFixtures().first)

        #expect(game.status.state == .final)
        #expect(game.round == "Third Round")
        #expect(game.home?.displayScore == "2")
        #expect(game.away?.displayScore == "4")
        #expect(game.away?.isWinner == true)
    }

    @Test func `a cup becomes the path of its rounds`() throws {
        let played = try scheduleFixtures()
        let next = SportsFixture(
            id: "next", leagueId: league.id, leagueName: league.name, leagueAbbreviation: "EFL",
            startDate: now.addingTimeInterval(20 * 86400), status: SportsFixtureStatus(state: .scheduled),
            home: SportsCompetitor(team: SportsTeam(leagueId: league.id, teamId: "999", name: "Fleetwood", shortName: "Fleetwood", abbreviation: "FLE")),
            away: SportsCompetitor(team: SportsTeam(leagueId: league.id, teamId: "359", name: "Arsenal", shortName: "Arsenal", abbreviation: "ARS")),
            round: "Fourth Round"
        )
        let card = try #require(SportsTeamSeasonBuilder.competition(
            .init(name: league.name, leagueId: league.id, isDomesticLeague: false, fixtures: played + [next], standings: []),
            teamId: "359", now: now
        ))

        guard case let .knockout(steps) = card.format else {
            Issue.record("expected a knockout path")
            return
        }
        #expect(steps.map(\.round) == ["Third Round", "Fourth Round"])
        #expect(steps.map(\.state) == [.won, .next])
        #expect(steps.first?.score == "4–2")
        #expect(steps.first?.opponent == "Ipswich")
        #expect(card.next?.id == "next")
    }

    @Test func `last season's cup run is left out`() throws {
        let old = try scheduleFixtures().map { game in
            SportsFixture(
                id: game.id, leagueId: game.leagueId, leagueName: game.leagueName, leagueAbbreviation: game.leagueAbbreviation,
                startDate: now.addingTimeInterval(-200 * 86400), status: game.status, home: game.home, away: game.away, round: game.round
            )
        }
        let card = SportsTeamSeasonBuilder.competition(
            .init(name: league.name, leagueId: league.id, isDomesticLeague: false, fixtures: old, standings: []),
            teamId: "359", now: now
        )
        #expect(card == nil)
    }

    @Test func `a league phase shows the place among all and the bands`() {
        let rows = (1 ... 36).map { rank in
            SportsStandingRow(
                id: "t\(rank)", teamId: rank == 5 ? "359" : "t\(rank)", name: "Team \(rank)", rank: rank, points: 40 - rank,
                note: rank <= 8 ? "Qualifies for round of 16" : rank <= 24 ? "Knockout play-off" : nil,
                noteColorHex: rank <= 8 ? "#81D6AC" : "#B2DCF2"
            )
        }
        let game = SportsFixture(
            id: "ucl", leagueId: "espn:soccer/uefa.champions", leagueName: "Champions League", leagueAbbreviation: "UCL",
            startDate: now.addingTimeInterval(-86400 * 20), status: SportsFixtureStatus(state: .final),
            home: SportsCompetitor(team: SportsTeam(leagueId: "x", teamId: "359", name: "Arsenal", shortName: "Arsenal", abbreviation: "ARS")),
            away: SportsCompetitor(team: SportsTeam(leagueId: "x", teamId: "1", name: "Napoli", shortName: "Napoli", abbreviation: "NAP")),
            round: "League Phase"
        )
        let card = SportsTeamSeasonBuilder.competition(
            .init(name: "Champions League", leagueId: "espn:soccer/uefa.champions", isDomesticLeague: false, fixtures: [game], standings: rows),
            teamId: "359", now: now
        )

        guard case let .leaguePhase(phase) = card?.format else {
            Issue.record("expected a league phase")
            return
        }
        #expect(phase.position == 5)
        #expect(phase.total == 36)
        #expect(phase.bands == [
            SportsStandingBand(first: 1, last: 8, label: "Qualifies for round of 16", colorHex: "#81D6AC"),
            SportsStandingBand(first: 9, last: 24, label: "Knockout play-off", colorHex: "#B2DCF2")
        ])
    }

    @Test func `the league table centres on the team`() {
        let rows = (1 ... 20).map { SportsStandingRow(id: "t\($0)", teamId: "t\($0)", name: "Team \($0)", rank: $0) }
        let middle = SportsTeamSeasonBuilder.table(rows, teamId: "t10")
        let top = SportsTeamSeasonBuilder.table(rows, teamId: "t1")

        #expect(middle?.rows.map(\.rank) == [8, 9, 10, 11, 12])
        #expect(top?.rows.map(\.rank) == [1, 2, 3, 4, 5])
    }

    @Test func `leaders keep the top three of each board, skipping empty boards`() {
        let squad = [
            SportsPlayerSeasonLine(name: "Saka", position: "F", appearances: 5, goals: 3, assists: 1, saves: 0),
            SportsPlayerSeasonLine(name: "Havertz", position: "F", appearances: 5, goals: 2, assists: 0, saves: 0),
            SportsPlayerSeasonLine(name: "Ødegaard", position: "M", appearances: 5, goals: 2, assists: 2, saves: 0),
            SportsPlayerSeasonLine(name: "Rice", position: "M", appearances: 4, goals: 1, assists: 0, saves: 0)
        ]
        let boards = SportsTeamSeasonBuilder.leaders(squad)

        #expect(boards.map(\.kind) == [.goals, .assists, .appearances])
        #expect(boards.first?.entries.map(\.name) == ["Saka", "Havertz", "Ødegaard"])
    }

    @Test func `the season turns over on 1 July`() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let march = calendar.date(from: DateComponents(year: 2027, month: 3, day: 1)) ?? now
        let september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)) ?? now
        #expect(SportsTeamSeasonBuilder.seasonStart(now: march, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        #expect(SportsTeamSeasonBuilder.seasonStart(now: september, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
    }
}

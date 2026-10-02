//
//  PlayerDetourMachineTests.swift
//  LumeTests
//
//  The way back from a live game to the film the viewer left: shown on
//  arrival, then with the controls; Back returns to the film where it was.
//

import Foundation
@testable import Lume
import Testing

struct PlayerDetourMachineTests {
    private let film = PlayableMedia(
        id: "movie-1", url: URL(fileURLWithPath: "/film.mkv"), title: "Film", subtitle: nil, posterURL: nil,
        kind: .vod, startTime: 0, contentRef: .movie("1")
    )

    @Test func `the pill shows on arrival, then only with the controls`() {
        var machine = PlayerDetourMachine()
        machine.handle(.began(.init(media: film, position: 4324)))
        #expect(machine.pillVisible(controlsVisible: false))

        machine.handle(.arrivalElapsed)
        #expect(!machine.pillVisible(controlsVisible: false))
        #expect(machine.pillVisible(controlsVisible: true))
    }

    @Test func `back returns to the film at the saved position`() {
        var machine = PlayerDetourMachine()
        machine.handle(.began(.init(media: film, position: 4324)))
        let effects = machine.handle(.backPressed)

        #expect(effects == [.returnTo(film.resuming(at: 4324))])
        #expect(machine.origin == nil)
    }

    @Test func `hopping to another game keeps the first way back`() {
        var machine = PlayerDetourMachine()
        machine.handle(.began(.init(media: film, position: 100)))
        let other = PlayableMedia(
            id: "movie-2", url: URL(fileURLWithPath: "/b.mkv"), title: "Other", subtitle: nil, posterURL: nil,
            kind: .vod, startTime: 0, contentRef: .movie("2")
        )
        machine.handle(.began(.init(media: other, position: 5)))

        #expect(machine.origin?.media.id == "movie-1")
    }

    @Test func `without a detour back is left to the engine`() {
        var machine = PlayerDetourMachine()
        #expect(machine.handle(.backPressed).isEmpty)
    }

    @Test func `alert candidates are followed teams' games on now or about to start`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let league = "espn:soccer/eng.1"
        func game(_ id: String, team: String, offset: TimeInterval) -> SportsFixture {
            SportsFixture(
                id: id, leagueId: league, leagueName: "", leagueAbbreviation: "",
                startDate: now.addingTimeInterval(offset), status: SportsFixtureStatus(state: .scheduled),
                home: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: team, name: team, shortName: team, abbreviation: team)),
                away: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "x", name: "x", shortName: "x", abbreviation: "x"))
            )
        }
        let followed: Set = ["\(league):1"]
        let picked = SportsAlertCoordinator.candidates([
            game("on", team: "1", offset: -1800),
            game("soon", team: "1", offset: 300),
            game("later", team: "1", offset: 3 * 3600),
            game("long-done", team: "1", offset: -5 * 3600),
            game("not-followed", team: "2", offset: -600)
        ], followedTeams: followed, now: now)

        #expect(picked.map(\.id) == ["on", "soon"])
    }
}

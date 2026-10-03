//
//  SportsSeasonLoadMachineTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct SportsSeasonLoadMachineTests {
    private func season(_ teamId: String) -> SportsTeamSeason {
        SportsTeamSeason(
            team: SportsTeam(leagueId: "espn:soccer/eng.1", teamId: teamId, name: teamId, shortName: teamId, abbreviation: ""),
            competitions: [], leaders: [], leadersCompetitionName: nil
        )
    }

    @Test func `a season belongs to the team it was loaded for`() {
        var machine = SportsTeamSeasonLoadMachine()
        let request = machine.begin(teamId: "363")
        #expect(machine.isLoading("363"))
        let applied = machine.finish(request, season: season("363"))
        #expect(applied)
        #expect(machine.season(for: "363") != nil)
        #expect(machine.season(for: "19970") == nil)
    }

    @Test func `a load for a team no longer shown is inert`() {
        var machine = SportsTeamSeasonLoadMachine()
        let old = machine.begin(teamId: "363")
        let current = machine.begin(teamId: "19970")
        let late = machine.finish(old, season: season("363"))
        #expect(!late)
        #expect(machine.isLoading("19970"))
        machine.finish(current, season: season("19970"))
        #expect(machine.season(for: "19970") != nil)
    }

    @Test func `nothing back settles instead of loading forever`() {
        var machine = SportsTeamSeasonLoadMachine()
        let request = machine.begin(teamId: "363")
        machine.finish(request, season: nil)
        #expect(!machine.isLoading("363"))
        #expect(machine.season(for: "363") == nil)
    }

    @Test func `a racing season is kept per series`() {
        var machine = SportsRacingSeasonLoadMachine()
        let old = machine.begin(leagueId: "espn:racing/f1")
        let current = machine.begin(leagueId: "espn:racing/irl")
        let late = machine.finish(old, season: nil)
        #expect(!late)
        machine.finish(current, season: nil)
        #expect(machine.season(for: "espn:racing/irl") == nil)
    }
}

//
//  SportsSeasonLoadMachineTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct SportsSeasonLoadMachineTests {
    @Test func `recreated season owners cannot accept the old request for the same team or league`() {
        var team = SportsTeamSeasonLoadMachine()
        let oldTeam = team.begin(teamId: "363")
        team = SportsTeamSeasonLoadMachine()
        let currentTeam = team.begin(teamId: "363")
        #expect(oldTeam != currentTeam)
        let accepted32 = team.finish(oldTeam, season: nil)
        #expect(!accepted32)
        #expect(team.isLoading("363"))
        let accepted33 = team.finish(currentTeam, season: nil)
        #expect(accepted33)
        let accepted34 = team.finish(currentTeam, season: nil)
        #expect(!accepted34)

        var racing = SportsRacingSeasonLoadMachine()
        let oldRacing = racing.begin(leagueId: "f1")
        racing = SportsRacingSeasonLoadMachine()
        let currentRacing = racing.begin(leagueId: "f1")
        #expect(oldRacing != currentRacing)
        let accepted35 = racing.finish(oldRacing, season: nil)
        #expect(!accepted35)
        let accepted36 = racing.finish(currentRacing, season: nil)
        #expect(accepted36)
        let accepted37 = racing.finish(currentRacing, season: nil)
        #expect(!accepted37)
    }

    @Test func `returning to a team retains only the newest request for it`() {
        var team = SportsTeamSeasonLoadMachine()
        let first = team.begin(teamId: "363")
        _ = team.begin(teamId: "19970")
        let current = team.begin(teamId: "363")
        let accepted38 = team.finish(first, season: season("363"))
        #expect(!accepted38)
        #expect(team.isLoading("363"))
        let accepted39 = team.finish(current, season: season("363"))
        #expect(accepted39)
    }

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

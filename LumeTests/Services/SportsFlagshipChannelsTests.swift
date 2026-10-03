//
//  SportsFlagshipChannelsTests.swift
//  LumeTests
//
//  Which channels count as a broadcaster's flagship: the built-in names through
//  IPTV prefixes and quality tags, never a secondary channel, and the viewer's
//  own marks either way. A game on one ranks as "On <channel>".
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsFlagshipChannelsTests {
    private let none = SportsFlagshipOverrides.Marks()

    @Test func `flagships are recognised through prefixes and quality tags`() {
        #expect(SportsFlagshipChannels.isFlagship("UK: SKY SPORTS MAIN EVENT FHD", overrides: none))
        #expect(SportsFlagshipChannels.isFlagship("DE | Sky Sport Bundesliga 1 HD", overrides: none))
        #expect(SportsFlagshipChannels.isFlagship("BBC One HD", overrides: none))
        #expect(SportsFlagshipChannels.isFlagship("[EN] TNT Sports 1", overrides: none))
    }

    @Test func `secondary channels are not flagships`() {
        #expect(!SportsFlagshipChannels.isFlagship("UK: Sky Sports Football HD", overrides: none))
        #expect(!SportsFlagshipChannels.isFlagship("TNT Sports 2", overrides: none))
        #expect(!SportsFlagshipChannels.isFlagship("Sky Sport Bundesliga 2", overrides: none))
        #expect(!SportsFlagshipChannels.isFlagship("BBC Two", overrides: none))
    }

    @Test func `the viewer's marks win either way`() {
        let name = "SuperSport Premier League"
        var marks = SportsFlagshipOverrides.Marks()
        marks.marked.insert(SportsFlagshipOverrides.key(for: name))
        marks.unmarked.insert(SportsFlagshipOverrides.key(for: "BBC One"))

        #expect(SportsFlagshipChannels.isFlagship(name, overrides: marks))
        #expect(!SportsFlagshipChannels.isFlagship("BBC One", overrides: marks))
    }

    @Test func `a game on a main channel ranks, named after the channel`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let league = "espn:soccer/eng.1"
        let game = SportsFixture(
            id: "g", leagueId: league, leagueName: "", leagueAbbreviation: "",
            startDate: now.addingTimeInterval(7200), status: SportsFixtureStatus(state: .scheduled),
            home: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "1", name: "Brentford", shortName: "Brentford", abbreviation: "")),
            away: SportsCompetitor(team: SportsTeam(leagueId: league, teamId: "2", name: "Fulham", shortName: "Fulham", abbreviation: ""))
        )
        let without = SportsHighlights.rank([game], standings: [:], followedTeamIds: [], availableIds: [], now: now)
        let with = SportsHighlights.rank(
            [game], standings: [:], followedTeamIds: [], availableIds: [], mainChannels: ["g": "Sky Sports Main Event"], now: now
        )

        #expect(without.isEmpty)
        #expect(with.first?.reason == .mainChannel("Sky Sports Main Event"))
    }
}

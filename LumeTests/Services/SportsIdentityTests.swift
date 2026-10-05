import Foundation
@testable import Lume
import Testing

struct SportsIdentityTests {
    @Test func `team ids split at the final delimiter without depending on an ESPN screen`() {
        #expect(SportsTeam.leagueID(fromTeamID: "espn:soccer/eng.1:359") == "espn:soccer/eng.1")
        #expect(SportsTeam.leagueID(fromTeamID: "other:region:league:42") == "other:region:league")
        #expect(SportsTeam.leagueID(fromTeamID: "") == nil)
        #expect(SportsTeam.leagueID(fromTeamID: ":42") == nil)
        #expect(SportsTeam.leagueID(fromTeamID: "359") == nil)
        // Grouping retains its historical unparseable-key fallback.
        #expect(SportsHubGrouping.leagueId(ofTeam: "359") == "359")
    }

    @Test func `home and away follows use qualified identity not a bare or cross league team number`() {
        let game = fixture(home: "eng.1", away: "ger.1")
        #expect(game.involves(anyOf: ["espn:soccer/eng.1:42"]))
        #expect(game.involves(anyOf: ["espn:soccer/ger.1:42"]))
        #expect(!game.involves(anyOf: ["42"]))
        #expect(!game.involves(anyOf: ["espn:soccer/fra.1:42"]))
        #expect(!game.involves(anyOf: []))
    }

    @Test func `a missing competitor or a competitorless event never matches a follow`() {
        #expect(fixture(home: nil, away: "ger.1").involves(anyOf: ["espn:soccer/ger.1:42"]))
        #expect(!fixture(home: "eng.1", away: nil).involves(anyOf: ["espn:soccer/ger.1:42"]))
        #expect(!fixture(home: nil, away: nil).involves(anyOf: ["espn:soccer/eng.1:42"]))
    }

    private func fixture(home: String?, away: String?) -> SportsFixture {
        SportsFixture(id: "fixture", leagueId: "espn:soccer/eng.1", leagueName: "League", leagueAbbreviation: "L",
                      startDate: Date(timeIntervalSince1970: 0), status: .init(state: .scheduled),
                      home: home.map(competitor), away: away.map(competitor))
    }

    private func competitor(_ slug: String) -> SportsCompetitor {
        SportsCompetitor(team: SportsTeam(leagueId: "espn:soccer/\(slug)", teamId: "42",
                                          name: "Team", shortName: "Team", abbreviation: "T"))
    }
}

import Foundation
@testable import Lume
import Testing

struct StandingsRowEmphasisTests {
    private let league = "espn:soccer/eng.1"

    private func fixture(home: String? = "1", away: String? = "2") -> SportsFixture {
        func competitor(_ id: String?) -> SportsCompetitor? {
            id.map {
                SportsCompetitor(team: SportsTeam(leagueId: league, teamId: $0, name: $0, shortName: $0, abbreviation: $0))
            }
        }
        return SportsFixture(
            id: "match", leagueId: league, leagueName: "League", leagueAbbreviation: "L",
            startDate: .distantPast, status: SportsFixtureStatus(state: .inProgress),
            home: competitor(home), away: competitor(away)
        )
    }

    private func emphasis(_ id: String, followed: Set<String> = []) -> StandingsRowEmphasis {
        StandingsRowEmphasis(
            row: SportsStandingRow(id: id, teamId: id, name: "Team", rank: 1),
            followedTeamIds: followed, playingTeamIds: fixture().standingsTeamIds
        )
    }

    @Test(arguments: ["1", "2"])
    func `both match teams are highlighted without following stars`(_ id: String) {
        let result = emphasis(id)
        #expect(result.isPlaying)
        #expect(!result.isFollowed)
        #expect(result.backgroundOpacity == 0.16)
    }

    @Test func `unrelated teams keep their existing followed or ordinary treatment`() {
        let ordinary = emphasis("11")
        #expect(!ordinary.isPlaying)
        #expect(!ordinary.isFollowed)
        #expect(ordinary.backgroundOpacity == 0)
        let followed = emphasis("3", followed: ["\(league):3"])
        #expect(followed.isFollowed)
        #expect(!followed.isPlaying)
        #expect(followed.backgroundOpacity == 0.08)
    }

    @Test func `a playing followed team keeps its star and stronger match highlight`() {
        let result = emphasis("1", followed: ["\(league):1"])
        #expect(result.isPlaying)
        #expect(result.isFollowed)
        #expect(result.backgroundOpacity == 0.16)
    }

    @Test func `missing competitors and empty IDs cannot match unrelated rows`() {
        #expect(fixture(home: nil, away: nil).standingsTeamIds.isEmpty)
        #expect(fixture(home: "", away: "2").standingsTeamIds == ["2"])
        let noTeam = SportsStandingRow(id: "1", name: "Unknown", rank: 1)
        #expect(!StandingsRowEmphasis(row: noTeam, followedTeamIds: [], playingTeamIds: ["1"]).isPlaying)
    }

    @Test func `non-team standings never highlight a coincidentally matching driver ID`() {
        let driver = SportsStandingRow(id: "1", kind: .driver, teamId: "1", name: "Driver", rank: 1)
        #expect(!StandingsRowEmphasis(row: driver, followedTeamIds: [], playingTeamIds: ["1"]).isPlaying)
    }
}

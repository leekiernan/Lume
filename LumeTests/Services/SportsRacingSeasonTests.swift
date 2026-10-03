//
//  SportsRacingSeasonTests.swift
//  LumeTests
//
//  A race series' season from its weekends: wins, poles and podiums counted
//  from the sessions' results, races left from the ones still to come.
//

import Foundation
@testable import Lume
import Testing

struct SportsRacingSeasonTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func weekend(_ id: String, offset: TimeInterval, quali: [String]?, race: [String]?) -> SportsFixture {
        let start = now.addingTimeInterval(offset)
        return SportsFixture(
            id: id, leagueId: "espn:racing/f1", leagueName: "F1", leagueAbbreviation: "F1",
            startDate: start, status: SportsFixtureStatus(state: race == nil ? .scheduled : .final),
            sessions: [
                SportsSession(kind: .qualifying, date: start.addingTimeInterval(86400), classification: quali),
                SportsSession(kind: .race, date: start.addingTimeInterval(2 * 86400), classification: race)
            ]
        )
    }

    @Test func `wins, poles and podiums come from the results; races left from the calendar`() {
        let weekends = [
            weekend("a", offset: -20 * 86400, quali: ["Russell", "Norris"], race: ["Russell", "Verstappen", "Norris"]),
            weekend("b", offset: -10 * 86400, quali: ["Norris", "Russell"], race: ["Norris", "Russell", "Piastri"]),
            weekend("c", offset: 5 * 86400, quali: nil, race: nil),
            weekend("d", offset: 12 * 86400, quali: nil, race: nil)
        ]
        let standings = [
            SportsStandingRow(id: "1", kind: .driver, name: "Russell", rank: 1, points: 43),
            SportsStandingRow(id: "2", kind: .driver, name: "Norris", rank: 2, points: 40)
        ]
        let season = SportsRacingSeason.build(weekends: weekends, standings: standings, now: now)

        #expect(season.racesLeft == 2)
        #expect(season.drivers.first == .init(name: "Russell", rank: 1, points: 43, wins: 1, poles: 1, podiums: 2))
        #expect(season.drivers.last == .init(name: "Norris", rank: 2, points: 40, wins: 1, poles: 1, podiums: 2))
        #expect(season.leadMargin?.leader == "Russell")
        #expect(season.leadMargin?.margin == 3)
    }
}

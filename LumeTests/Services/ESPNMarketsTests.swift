//
//  ESPNMarketsTests.swift
//  LumeTests
//
//  The game-detail extras from ESPN's summary: DraftKings moneylines become
//  decimal prices, the win-probability series' last play is the reading, and
//  the header's line scores become per-period rows. Shapes are trimmed from
//  real summaries (a Premier League match and an NFL game).
//

import Foundation
@testable import Lume
import Testing

struct ESPNMarketsTests {
    private func detail(_ json: String) throws -> SportsEventDetail {
        let response = try JSONDecoder().decode(ESPNSummaryResponse.self, from: Data(json.utf8))
        return ESPNClient.mapEventDetail(response)
    }

    @Test func `football moneylines become decimal prices with a draw`() throws {
        let detail = try detail("""
        {"pickcenter": [{"provider": {"name": "DraftKings"}, "details": "MAN +100",
          "homeTeamOdds": {"moneyLine": 250, "favorite": false},
          "awayTeamOdds": {"moneyLine": 100, "favorite": true},
          "drawOdds": {"moneyLine": 275.0}}]}
        """)

        let odds = try #require(detail.odds)
        #expect(odds.provider == "DraftKings")
        #expect(odds.home == 3.5)
        #expect(odds.away == 2.0)
        #expect(odds.draw == 3.75)
        let implied = try #require(odds.impliedProbabilities)
        #expect(abs(implied.home + implied.tie + implied.away - 1) < 0.0001)
        #expect(implied.away > implied.home)
    }

    @Test func `negative moneylines price the favourite under evens`() {
        #expect(SportsOdds.decimal(fromMoneyline: -150).map { ($0 * 100).rounded() / 100 } == 1.67)
        #expect(SportsOdds.decimal(fromMoneyline: 50) == nil)
    }

    @Test func `the last play is the win probability`() throws {
        let detail = try detail("""
        {"winprobability": [
          {"homeWinPercentage": 0.4475, "tiePercentage": 0.0, "playId": "1"},
          {"homeWinPercentage": 0.7591, "tiePercentage": 0.0, "playId": "2"}]}
        """)

        let probability = try #require(detail.winProbability)
        #expect(probability.home == 0.7591)
        #expect(abs(probability.away - 0.2409) < 0.0001)
    }

    @Test func `header line scores become period rows`() throws {
        let detail = try detail("""
        {"header": {"competitions": [{"competitors": [
          {"homeAway": "home", "linescores": [{"displayValue": "0"}, {"displayValue": "1"}]},
          {"homeAway": "away", "linescores": [{"displayValue": "0"}, {"displayValue": "1"}]}]}]}}
        """)

        #expect(detail.periodScores == SportsPeriodScores(home: ["0", "1"], away: ["0", "1"]))
    }

    @Test func `a summary without the blocks maps to none`() throws {
        let detail = try detail("{}")
        #expect(detail.odds == nil)
        #expect(detail.winProbability == nil)
        #expect(detail.periodScores == nil)
    }

    @Test func `decimal prices print like a bookmaker's`() {
        #expect(1.22.formattedDecimalOdds == 1.22.formatted(.number.precision(.fractionLength(2))))
        #expect(13.0.formattedDecimalOdds == 13.0.formatted(.number.precision(.fractionLength(1))))
    }
}

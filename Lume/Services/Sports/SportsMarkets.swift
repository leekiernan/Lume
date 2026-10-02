//
//  SportsMarkets.swift
//  Lume
//
//  The game-detail extras beyond the timeline: the bookmaker's match-result
//  prices, the provider's win probability and the score by period. Prices are
//  kept as decimal odds — what a UK viewer reads — converted from the
//  American moneylines ESPN serves.
//

import Foundation

nonisolated struct SportsOdds: Codable, Hashable {
    /// Who priced it ("DraftKings"), shown beside the numbers.
    let provider: String
    let home: Double?
    let draw: Double?
    let away: Double?

    /// The decimal price for an American moneyline: +250 → 3.50, −150 → 1.67.
    static func decimal(fromMoneyline moneyline: Double) -> Double? {
        if moneyline >= 100 { return 1 + moneyline / 100 }
        if moneyline <= -100 { return 1 + 100 / -moneyline }
        return nil
    }

    /// The outcome probabilities the prices imply, with the bookmaker's margin
    /// divided out so they sum to 1. `nil` without both sides' prices.
    var impliedProbabilities: SportsWinProbability? {
        guard let home, let away, home > 1, away > 1 else { return nil }
        let homeRaw = 1 / home, awayRaw = 1 / away
        let drawRaw = draw.map { $0 > 1 ? 1 / $0 : 0 } ?? 0
        let total = homeRaw + awayRaw + drawRaw
        guard total > 0 else { return nil }
        return SportsWinProbability(home: homeRaw / total, tie: drawRaw / total)
    }
}

nonisolated struct SportsWinProbability: Codable, Hashable {
    /// 0…1.
    let home: Double
    /// 0…1; zero where a game can't be drawn.
    let tie: Double

    var away: Double {
        max(0, 1 - home - tie)
    }
}

nonisolated struct SportsPeriodScores: Codable, Hashable {
    let home: [String]
    let away: [String]
}

nonisolated extension Double {
    /// A decimal price as bookmakers print it: two places below 10, one below
    /// 100 ("13.0"), whole numbers above.
    var formattedDecimalOdds: String {
        if self < 10 { return formatted(.number.precision(.fractionLength(2))) }
        if self < 100 { return formatted(.number.precision(.fractionLength(1))) }
        return formatted(.number.precision(.fractionLength(0)))
    }
}

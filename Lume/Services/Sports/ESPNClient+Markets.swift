//
//  ESPNClient+Markets.swift
//  Lume
//
//  Maps the summary's bookmaker lines, win probability and period scores
//  (split from ESPNClient.swift, at its length limit).
//

import Foundation

nonisolated extension ESPNClient {
    /// The first provider that prices both sides.
    static func mapOdds(_ pickcenter: [ESPNPickcenter]?) -> SportsOdds? {
        for line in pickcenter ?? [] {
            let home = line.homeTeamOdds?.moneyLine.flatMap(moneyline).flatMap(SportsOdds.decimal(fromMoneyline:))
            let away = line.awayTeamOdds?.moneyLine.flatMap(moneyline).flatMap(SportsOdds.decimal(fromMoneyline:))
            guard home != nil, away != nil else { continue }
            let draw = line.drawOdds?.moneyLine.flatMap(moneyline).flatMap(SportsOdds.decimal(fromMoneyline:))
            return SportsOdds(provider: line.provider?.name ?? "", home: home, draw: draw, away: away)
        }
        return nil
    }

    /// The latest play's probability.
    static func mapWinProbability(_ series: [ESPNWinProbability]?) -> SportsWinProbability? {
        guard let last = series?.last, let home = last.homeWinPercentage else { return nil }
        return SportsWinProbability(home: min(max(home, 0), 1), tie: min(max(last.tiePercentage ?? 0, 0), 1))
    }

    /// Both sides' per-period scores, when both have at least one.
    static func mapPeriodScores(_ header: ESPNSummaryHeader?) -> SportsPeriodScores? {
        let competitors = header?.competitions?.first?.competitors ?? []
        guard let home = competitors.first(where: { $0.homeAway == "home" }),
              let away = competitors.first(where: { $0.homeAway == "away" })
        else { return nil }
        let homeScores = (home.linescores ?? []).compactMap(\.displayValue)
        let awayScores = (away.linescores ?? []).compactMap(\.displayValue)
        guard !homeScores.isEmpty, homeScores.count == awayScores.count else { return nil }
        return SportsPeriodScores(home: homeScores, away: awayScores)
    }

    private static func moneyline(_ value: ESPNFlexibleValue) -> Double? {
        value.stringValue.flatMap(Double.init)
    }
}

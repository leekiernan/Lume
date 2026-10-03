//
//  ESPNDTOs+Summary.swift
//  Lume
//
//  The summary blocks behind the game-detail extras: `pickcenter` (bookmaker
//  lines), `winprobability` (per play, US sports) and the header's per-period
//  line scores. Only the fields read are declared.
//

import Foundation

nonisolated struct ESPNPickcenter: Codable, Hashable {
    let provider: ESPNOddsProvider?
    let homeTeamOdds: ESPNMoneylineOdds?
    let awayTeamOdds: ESPNMoneylineOdds?
    let drawOdds: ESPNMoneylineOdds?
}

nonisolated struct ESPNOddsProvider: Codable, Hashable {
    let name: String?
}

nonisolated struct ESPNMoneylineOdds: Codable, Hashable {
    /// An American price; a number in every feed seen, decoded flexibly.
    let moneyLine: ESPNFlexibleValue?
}

nonisolated struct ESPNWinProbability: Codable, Hashable {
    let homeWinPercentage: Double?
    let tiePercentage: Double?
}

nonisolated struct ESPNSummaryHeader: Codable, Hashable {
    let competitions: [ESPNSummaryHeaderCompetition]?
}

nonisolated struct ESPNSummaryHeaderCompetition: Codable, Hashable {
    let competitors: [ESPNSummaryHeaderCompetitor]?
}

nonisolated struct ESPNSummaryHeaderCompetitor: Codable, Hashable {
    let homeAway: String?
    let linescores: [ESPNPeriodLinescore]?
}

nonisolated struct ESPNPeriodLinescore: Codable, Hashable {
    let displayValue: String?
}

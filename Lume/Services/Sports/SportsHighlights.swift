//
//  SportsHighlights.swift
//  Lume
//
//  "Big this week": the events worth knowing about beyond the viewer's own
//  follows — finals, numbered UFC cards, top-of-the-table clashes, derbies,
//  Grand Prix race days. There is no attendance or audience figure to rank
//  by, so the stand-ins are what the fixtures and tables already say, each
//  scored, and the strongest named on the card as its reason.
//
//  Never ranked above the viewer's follows: a followed team's game is left out
//  here (it has its own rail), and the hub shows this section below them.
//

import Foundation

nonisolated struct SportsHighlight: Identifiable, Equatable {
    enum Reason: Equatable {
        case final
        case semiFinal
        case numberedCard
        case tableClash(Int, Int)
        case derby
        case raceDay
        case headline
    }

    let fixture: SportsFixture
    let reason: Reason
    let score: Int

    var id: String {
        fixture.id
    }
}

nonisolated enum SportsHighlights {
    static let window: TimeInterval = 7 * 86400
    static let threshold = 30
    static let limit = 8
    static let perSportLimit = 2

    /// How much a competition matters on its own.
    static func competitionWeight(_ leagueId: String) -> Int {
        switch leagueId {
        case "espn:soccer/uefa.champions", "espn:racing/f1": 30
        case "espn:soccer/eng.1", "espn:soccer/esp.1", "espn:soccer/ger.1", "espn:soccer/ita.1",
             "espn:football/nfl": 20
        case "espn:soccer/fra.1", "espn:soccer/uefa.europa", "espn:basketball/nba": 15
        default: 5
        }
    }

    /// Rivalries a derby boost applies to, by team name, either way round.
    static let derbies: [Set<String>] = [
        ["Arsenal", "Tottenham Hotspur"], ["Liverpool", "Everton"], ["Manchester United", "Manchester City"],
        ["Manchester United", "Liverpool"], ["Chelsea", "Tottenham Hotspur"], ["Real Madrid", "Barcelona"],
        ["Real Madrid", "Atlético Madrid"], ["Sevilla", "Real Betis"], ["Internazionale", "AC Milan"],
        ["AS Roma", "Lazio"], ["Juventus", "Torino"], ["Bayern Munich", "Borussia Dortmund"],
        ["Schalke 04", "Borussia Dortmund"], ["Paris Saint-Germain", "Marseille"], ["Celtic", "Rangers"],
        ["Ajax", "Feyenoord"], ["Benfica", "Sporting CP"], ["Boca Juniors", "River Plate"]
    ]

    /// Ranked highlights from `fixtures`, best first.
    /// - Parameters:
    ///   - standings: league id → table, for top-of-the-table clashes.
    ///   - availableIds: fixtures the viewer's channels carry.
    static func rank(
        _ fixtures: [SportsFixture],
        standings: [String: [SportsStandingRow]],
        followedTeamIds: Set<String>,
        availableIds: Set<String>,
        now: Date
    ) -> [SportsHighlight] {
        let candidates = fixtures.filter { fixture in
            let upcoming = fixture.status.state == .scheduled && fixture.startDate >= now
                && fixture.startDate <= now.addingTimeInterval(window)
            let followed = [fixture.home?.team.id, fixture.away?.team.id].compactMap(\.self).contains(where: followedTeamIds.contains)
            return (upcoming || fixture.isInProgress) && !followed
        }
        let scored = candidates.compactMap { fixture -> SportsHighlight? in
            let (score, reason) = evaluate(fixture, table: standings[fixture.leagueId] ?? [])
            var total = score
            if availableIds.contains(fixture.id) { total += 10 }
            if fixture.isInProgress { total += 5 }
            return total >= threshold ? SportsHighlight(fixture: fixture, reason: reason, score: total) : nil
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.fixture.startDate < $1.fixture.startDate }

        var perSport: [String: Int] = [:]
        var picked: [SportsHighlight] = []
        for highlight in scored where picked.count < limit {
            let sport = highlight.fixture.sport
            guard perSport[sport, default: 0] < perSportLimit else { continue }
            perSport[sport, default: 0] += 1
            picked.append(highlight)
        }
        return picked
    }

    /// The fixture's score and the strongest reason behind it.
    static func evaluate(_ fixture: SportsFixture, table: [SportsStandingRow]) -> (Int, SportsHighlight.Reason) {
        var score = competitionWeight(fixture.leagueId)
        var reasons: [(Int, SportsHighlight.Reason)] = [(score, .headline)]

        switch fixture.stage?.lowercased() {
        case "final":
            score += 50
            reasons.append((50, .final))
        case "semifinals", "semifinal", "semi-finals":
            score += 25
            reasons.append((25, .semiFinal))
        default:
            break
        }
        if fixture.sport == "mma", let name = fixture.name, name.range(of: #"^UFC \d+"#, options: .regularExpression) != nil {
            score += 35
            reasons.append((35, .numberedCard))
        }
        if fixture.sport == "racing", fixture.sessionKind == .race || (fixture.sessionKind == nil && fixture.raceSession != nil) {
            score += 10
            reasons.append((40, .raceDay))
        }
        if let clash = tableClash(fixture, table: table) {
            let boost = 25 + (5 - max(clash.0, clash.1)) * 2
            score += boost
            reasons.append((boost, .tableClash(clash.0, clash.1)))
        }
        if isDerby(fixture) {
            score += 30
            reasons.append((30, .derby))
        }
        let strongest = reasons.max { $0.0 < $1.0 }?.1 ?? .headline
        return (score, strongest)
    }

    /// Both sides' places when both are in the top four.
    static func tableClash(_ fixture: SportsFixture, table: [SportsStandingRow]) -> (Int, Int)? {
        guard let home = fixture.home?.team.teamId, let away = fixture.away?.team.teamId,
              let homeRank = table.first(where: { $0.teamId == home })?.rank,
              let awayRank = table.first(where: { $0.teamId == away })?.rank,
              homeRank <= 4, awayRank <= 4
        else { return nil }
        return (min(homeRank, awayRank), max(homeRank, awayRank))
    }

    static func isDerby(_ fixture: SportsFixture) -> Bool {
        guard let home = fixture.home?.team.name, let away = fixture.away?.team.name else { return false }
        return derbies.contains([home, away])
    }
}

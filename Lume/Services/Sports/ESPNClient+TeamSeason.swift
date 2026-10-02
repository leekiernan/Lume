//
//  ESPNClient+TeamSeason.swift
//  Lume
//
//  A team's own schedule in one competition (results, or fixtures to come)
//  and its squad's numbers, for the season view. A football team keeps one
//  ESPN id across competitions, so asking each competition for the same id
//  finds its cup runs too.
//

import Foundation

nonisolated extension ESPNClient {
    /// The team's games in `league`: played ones, or with `upcoming` the
    /// fixtures still to come. Each carries its round ("Third Round").
    func teamSchedule(league: SportsLeague, teamId: String, upcoming: Bool) async -> [SportsFixture] {
        var url = Self.siteAPIBase.appending(path: "\(league.sport)/\(league.slug)/teams/\(teamId)/schedule")
        if upcoming {
            url = url.appending(queryItems: [URLQueryItem(name: "fixture", value: "true")])
        }
        guard let response: ESPNScoreboard = await fetch(url) else { return [] }
        let rounds = Dictionary(
            (response.events ?? []).compactMap { event in event.id.map { ($0, event.seasonType?.name) } },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.mapScoreboard(response, league: league).map { fixture in
            fixture.withRound(rounds[fixture.id] ?? nil)
        }
    }

    /// Each squad member's numbers in `league` this season.
    func squad(league: SportsLeague, teamId: String) async -> [SportsPlayerSeasonLine] {
        let url = Self.siteAPIBase.appending(path: "\(league.sport)/\(league.slug)/teams/\(teamId)/roster")
        guard let response: ESPNTeamRosterResponse = await fetch(url) else { return [] }
        return (response.athletes ?? []).compactMap(Self.mapSquadLine)
    }

    static func mapSquadLine(_ athlete: ESPNTeamRosterAthlete) -> SportsPlayerSeasonLine? {
        guard let name = athlete.displayName else { return nil }
        var values: [String: Double] = [:]
        for category in athlete.statistics?.splits?.categories ?? [] {
            for stat in category.stats ?? [] {
                if let key = stat.name, let value = stat.value { values[key] = value }
            }
        }
        func int(_ key: String) -> Int {
            Int(values[key] ?? 0)
        }
        return SportsPlayerSeasonLine(
            name: name,
            position: athlete.position?.abbreviation,
            appearances: int("appearances"),
            goals: int("totalGoals"),
            assists: int("goalAssists"),
            saves: int("saves")
        )
    }
}

nonisolated extension SportsFixture {
    /// A copy naming its round.
    func withRound(_ round: String?) -> SportsFixture {
        SportsFixture(
            id: id, leagueId: leagueId, leagueName: leagueName, leagueAbbreviation: leagueAbbreviation,
            startDate: startDate, status: status, home: home, away: away, venue: venue,
            broadcasters: broadcasters, sessions: sessions, name: name, shortName: shortName,
            sessionKind: sessionKind, leagueLogoURL: leagueLogoURL, round: round ?? self.round,
            startTimeIsTentative: startTimeIsTentative, stage: stage
        )
    }
}

// MARK: - DTOs

nonisolated struct ESPNTeamRosterResponse: Codable, Hashable {
    let athletes: [ESPNTeamRosterAthlete]?
}

nonisolated struct ESPNTeamRosterAthlete: Codable, Hashable {
    let displayName: String?
    let position: ESPNPosition?
    let statistics: ESPNAthleteStatistics?
}

nonisolated struct ESPNAthleteStatistics: Codable, Hashable {
    let splits: ESPNAthleteStatSplit?
}

nonisolated struct ESPNAthleteStatSplit: Codable, Hashable {
    let categories: [ESPNAthleteStatCategory]?
}

nonisolated struct ESPNAthleteStatCategory: Codable, Hashable {
    let stats: [ESPNAthleteStat]?
}

nonisolated struct ESPNAthleteStat: Codable, Hashable {
    let name: String?
    let value: Double?
}

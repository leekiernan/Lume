//
//  SportsTeamSeasonLoader.swift
//  Lume
//
//  Gathers a football team's season from ESPN: its league's table, the UEFA
//  competitions and its country's cups — asked for the team's schedule in
//  each, keeping those it actually plays in this season — and its squad's
//  numbers in the league. Loaded when a season view opens and kept for half
//  an hour; nothing here is followed or refreshed in the background.
//

import Foundation
import Synchronization

nonisolated enum SportsTeamSeasonLoader {
    static let europeanSlugs = ["uefa.champions", "uefa.europa", "uefa.europa.conf"]

    /// Each country's domestic cups, by the prefix of its league slugs.
    static let cupSlugs: [String: [String]] = [
        "eng": ["eng.fa", "eng.league_cup"],
        "esp": ["esp.copa_del_rey"],
        "ger": ["ger.dfb_pokal"],
        "ita": ["ita.coppa_italia"],
        "fra": ["fra.coupe_de_france"],
        "ned": ["ned.cup"],
        "por": ["por.taca.portugal"],
        "sco": ["sco.tennents", "sco.cis"]
    ]

    private static let cacheLifetime: TimeInterval = 30 * 60
    private static let cache = Mutex<[String: (season: SportsTeamSeason, at: Date)]>([:])

    /// Football only: the season view's competitions are a football idea.
    static func supports(_ team: SportsTeam) -> Bool {
        SportsCatalog.league(id: team.leagueId)?.sport == "soccer"
    }

    static func load(team: SportsTeam, client: ESPNClient = .shared, now: Date = Date()) async -> SportsTeamSeason? {
        if let cached = cache.withLock({ $0[team.id] }), now.timeIntervalSince(cached.at) < cacheLifetime {
            return cached.season
        }
        guard let domestic = SportsCatalog.league(id: team.leagueId), domestic.sport == "soccer" else { return nil }
        let country = String(domestic.slug.split(separator: ".").first ?? "")
        let others = (europeanSlugs + (cupSlugs[country] ?? []))
            .compactMap { SportsCatalog.league(id: SportsLeague.makeID(sport: "soccer", slug: $0)) }

        async let domesticCard = competition(domestic, isDomesticLeague: true, team: team, client: client, now: now)
        async let squad = client.squad(league: domestic, teamId: team.teamId)
        let otherCards = await withTaskGroup(of: (Int, SportsSeasonCompetition?).self) { group in
            for (index, league) in others.enumerated() {
                group.addTask { await (index, competition(league, isDomesticLeague: false, team: team, client: client, now: now)) }
            }
            var cards: [(Int, SportsSeasonCompetition)] = []
            for await (index, card) in group {
                if let card { cards.append((index, card)) }
            }
            return cards.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // The league is the card that must be there: a failed or slow request
        // dropped it outright, then the half-hour cache kept the season
        // without it. Ask once more, and don't keep a season still missing it.
        var league = await domesticCard
        if league == nil {
            league = await competition(domestic, isDomesticLeague: true, team: team, client: client, now: now)
        }
        let season = await SportsTeamSeason(
            team: team,
            competitions: [league].compactMap(\.self) + otherCards,
            leaders: SportsTeamSeasonBuilder.leaders(squad),
            leadersCompetitionName: domestic.name
        )
        if league != nil {
            cache.withLock { $0[team.id] = (season, now) }
        }
        return season
    }

    private static func competition(
        _ league: SportsLeague,
        isDomesticLeague: Bool,
        team: SportsTeam,
        client: ESPNClient,
        now: Date
    ) async -> SportsSeasonCompetition? {
        async let results = client.teamSchedule(league: league, teamId: team.teamId, upcoming: false)
        async let fixtures = client.teamSchedule(league: league, teamId: team.teamId, upcoming: true)
        let games = await results + fixtures
        // Standings only where a table can matter: the league, and a UEFA
        // league phase the team is actually in.
        let needsTable = isDomesticLeague || (league.slug.hasPrefix("uefa.") && !games.isEmpty)
        let standings = await needsTable ? ((try? client.standings(league: league)) ?? []) : []
        return SportsTeamSeasonBuilder.competition(
            .init(name: league.name, leagueId: league.id, isDomesticLeague: isDomesticLeague, fixtures: games, standings: standings),
            teamId: team.teamId,
            now: now
        )
    }
}

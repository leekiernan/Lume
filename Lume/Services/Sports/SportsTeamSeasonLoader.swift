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
    static let womensEuropeanSlugs = ["uefa.wchampions"]

    /// The domestic leagues a team can be found in when it was followed from a
    /// European competition — men's and women's.
    static let domesticSlugs = ["eng.1", "esp.1", "ger.1", "ita.1", "fra.1", "ned.1", "por.1", "sco.1"]
    static let womensDomesticSlugs = ["eng.w.1", "esp.w.1", "fra.w.1", "ned.w.1"]

    /// Each country's women's cups.
    static let womensCupSlugs: [String: [String]] = [
        "eng": ["eng.w.fa", "eng.w.league_cup"],
        "esp": ["esp.copa_de_la_reina"]
    ]

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
        guard let followedFrom = SportsCatalog.league(id: team.leagueId), followedFrom.sport == "soccer" else { return nil }
        let isWomens = followedFrom.region == .womensFootball
        // The league the team was followed from isn't always its own: Chelsea
        // Women followed from the Champions League play in the WSL. ESPN's
        // team ids hold across competitions, so the league is found by asking.
        let domestic = await domesticLeague(for: team, followedFrom: followedFrom, isWomens: isWomens, client: client)
        let country = String(domestic.slug.split(separator: ".").first ?? "")
        let others = ((isWomens ? womensEuropeanSlugs : europeanSlugs)
            + ((isWomens ? womensCupSlugs : cupSlugs)[country] ?? []))
            .filter { $0 != domestic.slug }
            .compactMap { SportsCatalog.league(id: SportsLeague.makeID(sport: "soccer", slug: $0)) }

        async let domesticEntry = competition(domestic, isDomesticLeague: true, team: team, client: client, now: now)
        async let squad = client.squad(league: domestic, teamId: team.teamId)
        let otherEntries = await withTaskGroup(of: (Int, Entry).self) { group in
            for (index, league) in others.enumerated() {
                group.addTask { await (index, competition(league, isDomesticLeague: false, team: team, client: client, now: now)) }
            }
            var entries: [(Int, Entry)] = []
            for await entry in group {
                entries.append(entry)
            }
            return entries.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let otherCards = otherEntries.compactMap(\.card)
        // The league is the card that must be there: a failed or slow request
        // dropped it outright, then the half-hour cache kept the season
        // without it. Ask once more, and don't keep a season still missing it.
        var leagueEntry = await domesticEntry
        if leagueEntry.card == nil {
            leagueEntry = await competition(domestic, isDomesticLeague: true, team: team, client: client, now: now)
        }
        let league = leagueEntry.card
        let season = await SportsTeamSeason(
            team: team,
            competitions: [league].compactMap(\.self) + otherCards,
            leaders: SportsTeamSeasonBuilder.leaders(squad),
            leadersCompetitionName: domestic.name,
            upcoming: upcomingGames(([leagueEntry] + otherEntries).flatMap(\.games), now: now)
        )
        if league != nil {
            cache.withLock { $0[team.id] = (season, now) }
        }
        return season
    }

    /// The team's own league: the one it was followed from, unless that's a
    /// European competition — then the first domestic league that has it.
    private static func domesticLeague(
        for team: SportsTeam,
        followedFrom: SportsLeague,
        isWomens: Bool,
        client: ESPNClient
    ) async -> SportsLeague {
        // Only a European club competition says nothing about the team's own
        // league; any other is it.
        guard followedFrom.slug.hasPrefix("uefa.") else { return followedFrom }
        let slugs = isWomens ? womensDomesticSlugs : domesticSlugs
        let candidates = slugs.compactMap { SportsCatalog.league(id: SportsLeague.makeID(sport: "soccer", slug: $0)) }
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, league) in candidates.enumerated() {
                group.addTask {
                    await (index, !client.teamSchedule(league: league, teamId: team.teamId, upcoming: false).isEmpty)
                }
            }
            var found: [Int] = []
            for await (index, plays) in group where plays {
                found.append(index)
            }
            return found.min().map { candidates[$0] } ?? followedFrom
        }
    }

    /// A competition's card, if the team plays in it, and its games there.
    private struct Entry {
        let card: SportsSeasonCompetition?
        let games: [SportsFixture]
    }

    /// Live or still to play, once each, soonest first.
    static func upcomingGames(_ games: [SportsFixture], now: Date) -> [SportsFixture] {
        var byID: [String: SportsFixture] = [:]
        for game in games where game.isInProgress || (game.status.state == .scheduled && game.expectedEnd > now) {
            byID[game.id] = game
        }
        return byID.values.sorted(by: SportsFixture.displayOrder)
    }

    private static func competition(
        _ league: SportsLeague,
        isDomesticLeague: Bool,
        team: SportsTeam,
        client: ESPNClient,
        now: Date
    ) async -> Entry {
        async let results = client.teamSchedule(league: league, teamId: team.teamId, upcoming: false)
        async let fixtures = client.teamSchedule(league: league, teamId: team.teamId, upcoming: true)
        let games = await results + fixtures
        // Standings only where a table can matter: the league, and a UEFA
        // league phase the team is actually in.
        let needsTable = isDomesticLeague || (league.slug.hasPrefix("uefa.") && !games.isEmpty)
        let standings = await needsTable ? ((try? client.standings(league: league)) ?? []) : []
        let card = SportsTeamSeasonBuilder.competition(
            .init(name: league.name, leagueId: league.id, isDomesticLeague: isDomesticLeague, fixtures: games, standings: standings),
            teamId: team.teamId,
            now: now
        )
        return Entry(card: card, games: games)
    }
}

//
//  SportsHighlightsLoader.swift
//  Lume
//
//  The fixtures "Big this week" ranks, beyond what the viewer follows: the
//  headline competitions' next weeks, plus the big five leagues' tables for
//  top-of-the-table clashes. Fetched when the hub appears and kept for an
//  hour, in memory only — nothing here is followed, refreshed in the
//  background or written to disk.
//

import Foundation
import SwiftData
import Synchronization

nonisolated enum SportsHighlightsLoader {
    static let leagueIds = [
        "espn:soccer/uefa.champions", "espn:soccer/uefa.europa", "espn:soccer/eng.1", "espn:soccer/esp.1",
        "espn:soccer/ger.1", "espn:soccer/ita.1", "espn:soccer/fra.1", "espn:soccer/eng.fa",
        "espn:soccer/eng.league_cup", "espn:soccer/esp.copa_del_rey", "espn:soccer/ger.dfb_pokal",
        "espn:football/nfl", "espn:basketball/nba", "espn:racing/f1", "espn:mma/ufc"
    ]

    static let tableLeagueIds = [
        "espn:soccer/eng.1", "espn:soccer/esp.1", "espn:soccer/ger.1", "espn:soccer/ita.1", "espn:soccer/fra.1"
    ]

    struct Feed: Equatable {
        let fixtures: [SportsFixture]
        let standings: [String: [SportsStandingRow]]
    }

    fileprivate static let lifetime: TimeInterval = 3600
    fileprivate static let emptyLifetime: TimeInterval = 60
    private static let maxConcurrentRequests = 4
    private static let cache = SportsHighlightsFeedCache()

    static func load(client: ESPNClient = .shared, now: Date = Date()) async -> Feed {
        await cache.load(client: client, now: now)
    }

    /// One bounded pass over the public ESPN endpoints. Keeping the cap across
    /// both scoreboards and standings prevents a cold hub from creating a burst
    /// of thirty-plus requests, while the cache actor above coalesces callers.
    fileprivate static func loadUncached(client: ESPNClient, now: Date) async -> Feed {
        let months = SportsSyncService.monthsToFetch(for: now)
            + [Calendar.current.dateComponents([.year, .month], from: now.addingTimeInterval(SportsHighlights.window))]
        let uniqueMonths = Array(Set(months.map { MonthKey(year: $0.year ?? 0, month: $0.month ?? 0) }))
        let leagues = leagueIds.compactMap(SportsCatalog.league(id:))
        var requests: [Request] = []
        for league in leagues {
            for month in uniqueMonths {
                requests.append(.fixtures(league, month))
            }
        }
        requests += tableLeagueIds.compactMap(SportsCatalog.league(id:)).map(Request.standings)

        return await withTaskGroup(of: Response.self) { group in
            var next = 0
            var fixtures: [String: SportsFixture] = [:]
            var standings: [String: [SportsStandingRow]] = [:]

            while next < min(maxConcurrentRequests, requests.count) {
                let request = requests[next]
                next += 1
                group.addTask { await load(request, client: client, now: now) }
            }
            while let response = await group.next() {
                switch response {
                case let .fixtures(batch):
                    for fixture in batch {
                        fixtures[fixture.id] = fixture
                    }
                case let .standings(id, rows):
                    standings[id] = rows
                }
                if next < requests.count {
                    let request = requests[next]
                    next += 1
                    group.addTask { await load(request, client: client, now: now) }
                }
            }
            return Feed(fixtures: Array(fixtures.values), standings: standings)
        }
    }

    private nonisolated enum Request {
        case fixtures(SportsLeague, MonthKey)
        case standings(SportsLeague)
    }

    private nonisolated enum Response {
        case fixtures([SportsFixture])
        case standings(String, [SportsStandingRow])
    }

    private static func load(_ request: Request, client: ESPNClient, now: Date) async -> Response {
        switch request {
        case let .fixtures(league, month):
            let components = DateComponents(year: month.year, month: month.month)
            let raw = await (try? client.fixtures(league: league, month: components)) ?? []
            return .fixtures(raw.flatMap { $0.expandedBySession(now: now) })
        case let .standings(league):
            return await .standings(league.id, (try? client.standings(league: league)) ?? [])
        }
    }

    private nonisolated struct MonthKey: Hashable {
        let year: Int
        let month: Int
    }
}

/// Holds the short-lived feed independently of views. An empty result gets a
/// short backoff rather than hammering ESPN every time a surface remounts.
private actor SportsHighlightsFeedCache {
    private var cached: (feed: SportsHighlightsLoader.Feed, at: Date)?
    private var inFlight: Task<SportsHighlightsLoader.Feed, Never>?

    func load(client: ESPNClient, now: Date) async -> SportsHighlightsLoader.Feed {
        if let cached {
            let lifetime = cached.feed.fixtures.isEmpty ? SportsHighlightsLoader.emptyLifetime : SportsHighlightsLoader.lifetime
            if now.timeIntervalSince(cached.at) < lifetime { return cached.feed }
        }
        if let inFlight { return await inFlight.value }

        let task = Task.detached(priority: .utility) {
            await SportsHighlightsLoader.loadUncached(client: client, now: now)
        }
        inFlight = task
        let feed = await task.value
        cached = (feed, now)
        inFlight = nil
        return feed
    }
}

/// The whole "Big this week" pass a hub runs: load the feed, rank it, resolve
/// channels for the games a guide could already cover, and rank again with
/// that availability counted. Shared by the tvOS and iOS hubs.
nonisolated enum SportsHighlightsPipeline {
    struct Result: Equatable {
        let highlights: [SportsHighlight]
        let resolved: [String: [ResolvedChannel]]
    }

    static func run(
        container: ModelContainer,
        restriction: ContentRestriction,
        followedTeamIds: Set<String>,
        overrides: SportsFlagshipOverrides.Marks = .init(),
        now: Date = Date()
    ) async -> Result {
        let feed = await SportsHighlightsLoader.load(now: now)
        let firstPass = SportsHighlights.rank(
            feed.fixtures, standings: feed.standings, followedTeamIds: followedTeamIds, availableIds: [], now: now
        )
        let toResolve = firstPass.map(\.fixture).filter {
            $0.startDate.timeIntervalSince(now) < SportsChannelAvailability.guideHorizon && $0.expectedEnd > now
        }
        let resolved = toResolve.isEmpty
            ? [:]
            : await SportsChannelResolver.resolve(container: container, fixtures: toResolve, restriction: restriction)
        let available = Set(resolved.filter { !$0.value.isEmpty }.keys)
        // Games a guide already covers, checked against the viewer's flagship
        // channels only — a handful of guides, not every channel.
        let nearTerm = feed.fixtures.filter {
            $0.status.state == .scheduled && $0.startDate >= now
                && $0.startDate.timeIntervalSince(now) < SportsChannelAvailability.guideHorizon
        }
        let mainChannels = await SportsFlagshipChannels.mainChannels(
            for: nearTerm, container: container, restriction: restriction, overrides: overrides, now: now
        )
        let highlights = SportsHighlights.rank(
            feed.fixtures, standings: feed.standings, followedTeamIds: followedTeamIds,
            availableIds: available, mainChannels: mainChannels, now: now
        )
        return Result(highlights: highlights, resolved: resolved)
    }
}

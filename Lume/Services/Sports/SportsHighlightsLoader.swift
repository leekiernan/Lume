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

    private static let lifetime: TimeInterval = 3600
    private static let cache = Mutex<(feed: Feed, at: Date)?>(nil)

    static func load(client: ESPNClient = .shared, now: Date = Date()) async -> Feed {
        if let cached = cache.withLock({ $0 }), now.timeIntervalSince(cached.at) < lifetime {
            return cached.feed
        }
        let months = SportsSyncService.monthsToFetch(for: now)
            + [Calendar.current.dateComponents([.year, .month], from: now.addingTimeInterval(SportsHighlights.window))]
        let uniqueMonths = Array(Set(months.map { MonthKey(year: $0.year ?? 0, month: $0.month ?? 0) }))
        let leagues = leagueIds.compactMap(SportsCatalog.league(id:))

        async let fixtures = withTaskGroup(of: [SportsFixture].self) { group in
            for league in leagues {
                for month in uniqueMonths {
                    group.addTask {
                        let components = DateComponents(year: month.year, month: month.month)
                        let raw = await (try? client.fixtures(league: league, month: components)) ?? []
                        return raw.flatMap { $0.expandedBySession(now: now) }
                    }
                }
            }
            var all: [String: SportsFixture] = [:]
            for await batch in group {
                for fixture in batch {
                    all[fixture.id] = fixture
                }
            }
            return Array(all.values)
        }
        async let standings = withTaskGroup(of: (String, [SportsStandingRow]).self) { group in
            for league in tableLeagueIds.compactMap(SportsCatalog.league(id:)) {
                group.addTask { await (league.id, (try? client.standings(league: league)) ?? []) }
            }
            var tables: [String: [SportsStandingRow]] = [:]
            for await (id, rows) in group {
                tables[id] = rows
            }
            return tables
        }
        let feed = await Feed(fixtures: fixtures, standings: standings)
        if !feed.fixtures.isEmpty {
            cache.withLock { $0 = (feed, now) }
        }
        return feed
    }

    private struct MonthKey: Hashable {
        let year: Int
        let month: Int
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

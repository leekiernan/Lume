//
//  SectionFeedCacheTests.swift
//  LumeTests
//
//  Freshness and request-identity contracts for configurable remote sections.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct SectionFeedCacheTests {
    @Test func `feed types expire on their own explicit lifetimes`() throws {
        let cache = SectionFeedCache()
        let storedAt = Date(timeIntervalSince1970: 1_700_000_000)
        cache.storeTrending(
            .home,
            key: "trending",
            entry: .init(movies: .empty, series: .empty),
            now: storedAt
        )
        cache.storeWatchlist(.home, .trakt, key: "watchlist", collection: .empty, now: storedAt)
        cache.storeCustom(.home, key: "custom", collections: [:], now: storedAt)

        #expect(try #require(cache.trendingEntry(
            .home, for: "trending",
            now: storedAt.addingTimeInterval(SectionFeedCache.trendingLifetime)
        )).isFresh)
        #expect(try !(#require(cache.watchlistEntry(
            .home, .trakt, for: "watchlist",
            now: storedAt.addingTimeInterval(SectionFeedCache.watchlistLifetime + 1)
        )).isFresh))
        #expect(try !(#require(cache.customEntry(
            .home, for: "custom",
            now: storedAt.addingTimeInterval(SectionFeedCache.customLifetime + 1)
        )).isFresh))
    }

    @Test func `cache entries remain isolated by surface, service and key`() {
        let cache = SectionFeedCache()
        cache.storeWatchlist(.home, .trakt, key: "account-a", collection: .empty)

        #expect(cache.watchlistEntry(.home, .trakt, for: "account-a") != nil)
        #expect(cache.watchlistEntry(.movies, .trakt, for: "account-a") == nil)
        #expect(cache.watchlistEntry(.home, .trakt, for: "account-b") == nil)
        // Trakt and Simkl rows share a surface but never each other's entry.
        #expect(cache.watchlistEntry(.home, .simkl, for: "account-a") == nil)
    }

    @Test func `new requests and context changes revoke older responses`() {
        let gate = SectionFeedLoadGate()
        let first = gate.begin(.trending)
        let second = gate.begin(.trending)

        #expect(!gate.isCurrent(first, for: .trending))
        #expect(gate.isCurrent(second, for: .trending))
        #expect(!gate.isCurrent(second, for: .watchlist(.trakt)))

        // One service's watchlist load never supersedes the other's.
        let trakt = gate.begin(.watchlist(.trakt))
        _ = gate.begin(.watchlist(.simkl))
        #expect(gate.isCurrent(trakt, for: .watchlist(.trakt)))

        gate.invalidateAll()
        #expect(!gate.isCurrent(second, for: .trending))
    }

    @Test func `each watchlist row maps to exactly one service`() {
        for provider in WatchlistProvider.allCases {
            #expect(WatchlistProvider(section: provider.section) == provider)
        }
        #expect(WatchlistProvider(section: .trendingMovies) == nil)
    }
}

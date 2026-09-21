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
        cache.storeWatchlist(.home, key: "watchlist", collection: .empty, now: storedAt)
        cache.storeCustom(.home, key: "custom", collections: [:], now: storedAt)

        #expect(try #require(cache.trendingEntry(
            .home, for: "trending",
            now: storedAt.addingTimeInterval(SectionFeedCache.trendingLifetime)
        )).isFresh)
        #expect(try !(#require(cache.watchlistEntry(
            .home, for: "watchlist",
            now: storedAt.addingTimeInterval(SectionFeedCache.watchlistLifetime + 1)
        )).isFresh))
        #expect(try !(#require(cache.customEntry(
            .home, for: "custom",
            now: storedAt.addingTimeInterval(SectionFeedCache.customLifetime + 1)
        )).isFresh))
    }

    @Test func `cache entries remain isolated by surface and key`() {
        let cache = SectionFeedCache()
        cache.storeWatchlist(.home, key: "account-a", collection: .empty)

        #expect(cache.watchlistEntry(.home, for: "account-a") != nil)
        #expect(cache.watchlistEntry(.movies, for: "account-a") == nil)
        #expect(cache.watchlistEntry(.home, for: "account-b") == nil)
    }

    @Test func `new requests and context changes revoke older responses`() {
        let gate = SectionFeedLoadGate()
        let first = gate.begin(.trending)
        let second = gate.begin(.trending)

        #expect(!gate.isCurrent(first, for: .trending))
        #expect(gate.isCurrent(second, for: .trending))
        #expect(!gate.isCurrent(second, for: .watchlist))

        gate.invalidateAll()
        #expect(!gate.isCurrent(second, for: .trending))
    }
}

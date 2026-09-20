//
//  HomeTrendingCacheTests.swift
//  LumeTests
//
//  Freshness and request-identity contracts for Home's remote feeds.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct HomeTrendingCacheTests {
    @Test func `trending cache serves stale values without calling them fresh`() throws {
        let cache = HomeTrendingCache()
        let storedAt = Date(timeIntervalSince1970: 1_700_000_000)
        cache.storeTrending(key: "home", heroes: [], movies: [], series: [], now: storedAt)

        let fresh = try #require(cache.trendingEntry(
            for: "home",
            now: storedAt.addingTimeInterval(HomeTrendingCache.trendingLifetime)
        ))
        let stale = try #require(cache.trendingEntry(
            for: "home",
            now: storedAt.addingTimeInterval(HomeTrendingCache.trendingLifetime + 1)
        ))

        #expect(fresh.isFresh)
        #expect(!stale.isFresh)
        #expect(cache.trendingEntry(for: "another-home", now: storedAt) == nil)
    }

    @Test func `watchlist has its own shorter freshness window`() throws {
        let cache = HomeTrendingCache()
        let storedAt = Date(timeIntervalSince1970: 1_700_000_000)
        cache.storeWatchlist(key: "watchlist", items: [], now: storedAt)

        let fresh = try #require(cache.watchlistEntry(
            for: "watchlist",
            now: storedAt.addingTimeInterval(HomeTrendingCache.watchlistLifetime)
        ))
        let stale = try #require(cache.watchlistEntry(
            for: "watchlist",
            now: storedAt.addingTimeInterval(HomeTrendingCache.watchlistLifetime + 1)
        ))

        #expect(fresh.isFresh)
        #expect(!stale.isFresh)
    }

    @Test func `a later request supersedes an earlier request with the same cache key`() {
        let gate = HomeRemoteLoadGate()
        let first = gate.begin(.trending)
        let second = gate.begin(.trending)

        #expect(!gate.isCurrent(first, for: .trending))
        #expect(gate.isCurrent(second, for: .trending))
        #expect(!gate.isCurrent(second, for: .watchlist))
    }
}

//
//  HomeTrendingCache.swift
//  Lume
//
//  Session-lived stale-while-revalidate cache for Home's TMDB trending and
//  Trakt watchlist results.
//  tvOS renders only the selected tab, so `HomeView` (and its `@State`) is
//  torn down on every tab switch — without this cache the hero carousel
//  refetched and visibly popped in on each return to Home. Entries are keyed
//  by the same invalidation keys the loading tasks use, so a playlist switch,
//  sync or added playlist still reloads; a cache entry is only read after its
//  key matches, so stale model references from a removed playlist are never
//  touched. Matching stale entries remain useful for the first frame, then
//  refresh in the background according to the explicit lifetimes below.
//

import Foundation

@MainActor
@Observable
final class HomeTrendingCache {
    static let shared = HomeTrendingCache()

    static let trendingLifetime: TimeInterval = 30 * 60
    static let watchlistLifetime: TimeInterval = 5 * 60

    struct Lookup<Value> {
        let value: Value
        let isFresh: Bool
    }

    struct TrendingValue {
        let heroes: [HeroItem]
        let movies: [HomeMediaItem]
        let series: [HomeMediaItem]
    }

    private(set) var trendingKey: String?
    private(set) var heroItems: [HeroItem] = []
    private(set) var trendingMovies: [HomeMediaItem] = []
    private(set) var trendingSeries: [HomeMediaItem] = []
    private var trendingStoredAt: Date?

    private(set) var watchlistKey: String?
    private(set) var watchlist: [HomeMediaItem] = []
    private var watchlistStoredAt: Date?

    func trendingEntry(for key: String, now: Date = .now) -> Lookup<TrendingValue>? {
        guard key == trendingKey, let storedAt = trendingStoredAt else { return nil }
        return Lookup(
            value: TrendingValue(heroes: heroItems, movies: trendingMovies, series: trendingSeries),
            isFresh: now.timeIntervalSince(storedAt) <= Self.trendingLifetime
        )
    }

    func storeTrending(
        key: String,
        heroes: [HeroItem],
        movies: [HomeMediaItem],
        series: [HomeMediaItem],
        now: Date = .now
    ) {
        trendingKey = key
        heroItems = heroes
        trendingMovies = movies
        trendingSeries = series
        trendingStoredAt = now
    }

    func watchlistEntry(for key: String, now: Date = .now) -> Lookup<[HomeMediaItem]>? {
        guard key == watchlistKey, let storedAt = watchlistStoredAt else { return nil }
        return Lookup(
            value: watchlist,
            isFresh: now.timeIntervalSince(storedAt) <= Self.watchlistLifetime
        )
    }

    func storeWatchlist(key: String, items: [HomeMediaItem], now: Date = .now) {
        watchlistKey = key
        watchlist = items
        watchlistStoredAt = now
    }
}

/// Separates request identity from cache identity. A key can cycle A → B → A
/// during rapid profile/playlist switching; checking only the key would allow
/// the first A request to publish over the newer one.
@MainActor
final class HomeRemoteLoadGate {
    enum Feed: Hashable {
        case trending
        case watchlist
    }

    private var current: [Feed: UUID] = [:]

    func begin(_ feed: Feed) -> UUID {
        let id = UUID()
        current[feed] = id
        return id
    }

    func isCurrent(_ id: UUID, for feed: Feed) -> Bool {
        current[feed] == id
    }
}

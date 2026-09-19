//
//  SectionFeedCache.swift
//  Lume
//
//  Session-lived memo of the remote-backed rows on each section surface: TMDB
//  trending, the Trakt watchlist and the user's custom list rows. tvOS renders
//  only the selected tab, so a surface's view (and its state) is torn down on
//  every tab switch — without this cache the hero carousel refetched and
//  visibly popped in on each return to Home, and the Movies/Series pages would
//  do the same.
//
//  Entries are keyed by surface *and* by the same invalidation keys the loading
//  tasks use, so a playlist switch, sync or added playlist still reloads; an
//  entry is only read once its key matches, so stale model references from a
//  removed playlist are never touched.
//

import Foundation

@MainActor
@Observable
final class SectionFeedCache {
    static let shared = SectionFeedCache()

    struct TrendingEntry {
        let movies: SectionCollectionSnapshot
        let series: SectionCollectionSnapshot
    }

    /// One slot per surface per feed, so Home's trending memo and the Movies
    /// page's never clobber each other.
    private var trending: [SectionSurface: (key: String, value: TrendingEntry)] = [:]
    private var watchlist: [SectionSurface: (key: String, value: SectionCollectionSnapshot)] = [:]
    private var custom: [SectionSurface: (key: String, value: [UUID: SectionCollectionSnapshot])] = [:]

    func trendingEntry(_ surface: SectionSurface, for key: String) -> TrendingEntry? {
        guard let slot = trending[surface], slot.key == key else { return nil }
        return slot.value
    }

    func storeTrending(_ surface: SectionSurface, key: String, entry: TrendingEntry) {
        trending[surface] = (key, entry)
    }

    func watchlistEntry(_ surface: SectionSurface, for key: String) -> SectionCollectionSnapshot? {
        guard let slot = watchlist[surface], slot.key == key else { return nil }
        return slot.value
    }

    func storeWatchlist(_ surface: SectionSurface, key: String, collection: SectionCollectionSnapshot) {
        watchlist[surface] = (key, collection)
    }

    func customEntry(_ surface: SectionSurface, for key: String) -> [UUID: SectionCollectionSnapshot]? {
        guard let slot = custom[surface], slot.key == key else { return nil }
        return slot.value
    }

    func storeCustom(_ surface: SectionSurface, key: String, collections: [UUID: SectionCollectionSnapshot]) {
        custom[surface] = (key, collections)
    }
}

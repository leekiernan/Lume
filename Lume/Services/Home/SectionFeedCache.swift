//
//  SectionFeedCache.swift
//  Lume
//
//  Session-lived stale-while-revalidate cache of the remote-backed rows on each
//  section surface: TMDB trending, the Trakt watchlist and the user's custom
//  list rows. tvOS renders
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

    static let trendingLifetime: TimeInterval = 30 * 60
    static let watchlistLifetime: TimeInterval = 5 * 60
    static let customLifetime: TimeInterval = 15 * 60

    struct Lookup<Value> {
        let value: Value
        let isFresh: Bool
    }

    struct TrendingEntry {
        let movies: SectionCollectionSnapshot
        let series: SectionCollectionSnapshot
    }

    private struct Slot<Value> {
        let key: String
        let value: Value
        let storedAt: Date
    }

    /// One slot per surface per feed, so Home's trending memo and the Movies
    /// page's never clobber each other.
    private var trending: [SectionSurface: Slot<TrendingEntry>] = [:]
    private var watchlist: [SectionSurface: Slot<SectionCollectionSnapshot>] = [:]
    private var custom: [SectionSurface: Slot<[UUID: SectionCollectionSnapshot]>] = [:]

    func trendingEntry(_ surface: SectionSurface, for key: String, now: Date = .now) -> Lookup<TrendingEntry>? {
        guard let slot = trending[surface], slot.key == key else { return nil }
        return lookup(slot, lifetime: Self.trendingLifetime, now: now)
    }

    func storeTrending(_ surface: SectionSurface, key: String, entry: TrendingEntry, now: Date = .now) {
        trending[surface] = Slot(key: key, value: entry, storedAt: now)
    }

    func watchlistEntry(
        _ surface: SectionSurface,
        for key: String,
        now: Date = .now
    ) -> Lookup<SectionCollectionSnapshot>? {
        guard let slot = watchlist[surface], slot.key == key else { return nil }
        return lookup(slot, lifetime: Self.watchlistLifetime, now: now)
    }

    func storeWatchlist(
        _ surface: SectionSurface,
        key: String,
        collection: SectionCollectionSnapshot,
        now: Date = .now
    ) {
        watchlist[surface] = Slot(key: key, value: collection, storedAt: now)
    }

    func customEntry(
        _ surface: SectionSurface,
        for key: String,
        now: Date = .now
    ) -> Lookup<[UUID: SectionCollectionSnapshot]>? {
        guard let slot = custom[surface], slot.key == key else { return nil }
        return lookup(slot, lifetime: Self.customLifetime, now: now)
    }

    func storeCustom(
        _ surface: SectionSurface,
        key: String,
        collections: [UUID: SectionCollectionSnapshot],
        now: Date = .now
    ) {
        custom[surface] = Slot(key: key, value: collections, storedAt: now)
    }

    private func lookup<Value>(_ slot: Slot<Value>, lifetime: TimeInterval, now: Date) -> Lookup<Value> {
        Lookup(value: slot.value, isFresh: now.timeIntervalSince(slot.storedAt) <= lifetime)
    }
}

/// Request identity is separate from cache identity. A key can cycle A → B → A
/// during rapid playlist switching; the first A response must not publish over
/// the newer A request merely because their string keys match again.
@MainActor
final class SectionFeedLoadGate {
    enum Feed: Hashable {
        case trending
        case watchlist
        case custom
    }

    struct Request {
        fileprivate let id: UUID
        fileprivate let revision: UInt
    }

    private var current: [Feed: UUID] = [:]
    private(set) var revision: UInt = 0

    func begin(_ feed: Feed) -> Request {
        let id = UUID()
        current[feed] = id
        return Request(id: id, revision: revision)
    }

    func isCurrent(_ request: Request, for feed: Feed) -> Bool {
        !Task.isCancelled
            && request.revision == revision
            && current[feed] == request.id
    }

    func invalidateAll() {
        revision &+= 1
        current.removeAll()
    }
}

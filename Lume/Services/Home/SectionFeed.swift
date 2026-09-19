//
//  SectionFeed.swift
//  Lume
//
//  The remote-backed rows shared by every section surface (Home, Movies,
//  Series): TMDB trending, the Trakt watchlist, and the user's custom list
//  rows. Each surface owns one `SectionFeed`; the locally-queried rows
//  (Recently Watched, Favorites, Recently Added) stay as @Query-backed views.
//
//  Everything here matches remote titles against the local catalog by TMDB id
//  in batched queries, so a row only ever shows titles the active playlist
//  actually carries. `surface.mediaType` narrows that to one medium on the
//  Movies and Series pages — a movie list added there simply resolves to
//  nothing on the Series page rather than showing the wrong medium.
//

import SwiftData
import SwiftUI

@MainActor
@Observable
final class SectionFeed {
    /// What a load needs from the view: the store to match against, the
    /// viewer's hidden categories, and the active playlist's id prefix (nil
    /// means "no playlist scoping", which is what previews get).
    struct Context {
        let modelContext: ModelContext
        let restriction: ContentRestriction
        let playlistPrefix: String?

        func belongsToActivePlaylist(_ id: String) -> Bool {
            guard let playlistPrefix else { return true }
            return id.hasPrefix(playlistPrefix)
        }
    }

    let surface: SectionSurface

    /// Which row the surface shows as its hero, set from its stored preference
    /// before each load. Nothing stands in for it while that row loads, so the
    /// hero opens on its own content or on nothing, never on someone else's.
    var heroRef: HomeSectionRef?
    /// Bumped when hero artwork lands — see `refreshHeroArtwork`.
    private(set) var heroArtworkRevision = 0
    /// Every remote-backed row shares one representation: its lightweight
    /// ordered source plus a bounded catalog preview. The source tail remains
    /// available for an incrementally-loaded full grid without keeping all of
    /// its SwiftData models alive on the browse screen.
    private(set) var collections: [HomeSectionRef: SectionCollectionSnapshot] = [:]
    private(set) var trendingState: HomeLoadState = .idle

    /// How many matched titles a remote-backed row shows.
    static let itemLimit = 20
    /// How many hero candidates the Home carousel pages through.
    private static let heroLimit = 8

    init(surface: SectionSurface) {
        self.surface = surface
    }

    func items(for section: HomeSectionRef) -> [HomeMediaItem] {
        collections[section]?.preview ?? []
    }

    func collection(for section: HomeSectionRef) -> SectionCollectionSnapshot? {
        collections[section]
    }

    /// Resolves another local-catalog window from the retained source list.
    /// Nothing calls this from the 20-card rail; it is the common continuation
    /// path a full collection grid can use without refetching its remote list.
    func page(
        for section: HomeSectionRef,
        from cursor: Int,
        limit: Int = 100
    ) -> SectionCollectionPage {
        guard let collection = collections[section], let context else {
            return SectionCollectionPage(items: [], nextOffset: cursor, hasMoreCandidates: false)
        }
        return SectionCollectionResolver.page(
            entries: collection.entries,
            from: cursor,
            limit: limit,
            context: context
        )
    }

    /// The promoted row's titles, as hero slides. Titles whose backdrop hasn't
    /// been fetched yet are held back rather than shown as a stretched poster;
    /// `refreshHeroArtwork` fills them in and they appear on the next pass.
    var heroItems: [HeroItem] {
        // Observed so the hero recomputes once enrichment fills in backdrops.
        _ = heroArtworkRevision
        return heroCandidates
            .filter(\.hasWideArtwork)
            .prefix(Self.heroLimit)
            .map(\.self)
    }

    /// Everything the promoted row resolved to, artwork or not.
    private var heroCandidates: [HeroItem] {
        guard let heroRef else { return [] }
        return items(for: heroRef).compactMap(HeroItem.init(item:))
    }

    /// True once every remote row has settled, so a surface can tell "still
    /// loading" from "genuinely empty" before showing an empty state.
    var isSettled: Bool {
        trendingState.isSettled
    }

    // MARK: - Trending

    func loadTrending(cacheKey: String) async {
        // Session cache: see `SectionFeedCache`.
        if let cached = SectionFeedCache.shared.trendingEntry(surface, for: cacheKey) {
            collections[.builtin(.trendingMovies)] = cached.movies
            collections[.builtin(.trendingSeries)] = cached.series
            trendingState = .loaded
            return
        }
        guard let context else { return }
        let client = TMDBClient.shared
        guard client.isConfigured else {
            trendingState = .loaded
            return
        }
        trendingState = .loading
        let interval = Perf.begin(.homeTrendingLoad)
        defer { Perf.end(interval) }
        do {
            // A scoped surface only ever renders one medium, so don't pay for
            // the other feed there.
            async let movieTitles = surface.mediaType == .series ? [] : client.trending(.movie)
            async let tvTitles = surface.mediaType == .movie ? [] : client.trending(.tvShow)
            let (movies, tvSeries) = try await (movieTitles, tvTitles)

            let movieCollection = makeCollection(
                entries: movies.map {
                    HomeListEntry(tmdbId: $0.id, mediaType: .movie, title: $0.title)
                },
                context: context
            )
            let seriesCollection = makeCollection(
                entries: tvSeries.map {
                    HomeListEntry(tmdbId: $0.id, mediaType: .series, title: $0.title)
                },
                context: context
            )
            collections[.builtin(.trendingMovies)] = movieCollection
            collections[.builtin(.trendingSeries)] = seriesCollection
            trendingState = .loaded
            SectionFeedCache.shared.storeTrending(surface, key: cacheKey, entry: .init(
                movies: movieCollection,
                series: seriesCollection
            ))
            await refreshHeroArtwork()
        } catch {
            trendingState = .failed
        }
    }

    /// The TMDB trending feed carries no logo artwork, so a hero title shows
    /// only its backdrop until its full details are fetched.
    /// A promoted section has neither: its entries are just ids, so the hero
    /// depends entirely on what enrichment has stored on the catalog model. That fetch used to
    /// happen only on the detail screen, so logos "popped in" after visiting
    /// Details and coming back. Enrich the visible hero titles up front via the
    /// same TMDB detail path. Runs after the carousel is shown so backdrops
    /// aren't blocked.
    /// Fetches the wide artwork, logo and copy for hero candidates that are
    /// missing any of it, on the sync manager's background context. The saves
    /// auto-merge, so the hero picks them up without a main-thread store write.
    private func enrichHeroArtwork(_ heroes: [HeroItem], context: Context) async {
        guard !heroes.isEmpty else { return }
        // Enrich on the manager's background context; the saves auto-merge back
        // so the hero models pick up their logos without a main-thread store
        // write blocking the carousel.
        let manager = ContentSyncManager(modelContainer: context.modelContext.container)
        for hero in heroes {
            switch hero {
            case let .movie(movie, _, _):
                guard Self.heroNeedsArtwork(
                    backdropPath: movie.backdropPath,
                    logoPath: movie.logoPath,
                    enrichedAt: movie.tmdbEnrichedAt
                ), let tmdbId = movie.tmdbId else { continue }
                await manager.enrichMovie(id: movie.id, tmdbId: tmdbId)
            case let .series(series, _, _):
                guard Self.heroNeedsArtwork(
                    backdropPath: series.backdropPath,
                    logoPath: series.logoPath,
                    enrichedAt: series.tmdbEnrichedAt
                ), let tmdbId = series.tmdbId else { continue }
                await manager.enrichSeries(id: series.id, tmdbId: tmdbId)
            }
        }
    }

    /// A hero needs a fetch when it is missing its wide artwork or its logo and
    /// hasn't been enriched recently. The recency guard mirrors the detail
    /// screen's 14-day window so titles TMDB simply has no backdrop or logo for
    /// aren't refetched on every appearance — `tmdbEnrichedAt` is stamped only
    /// on a successful fetch, so "enriched but still no backdrop" genuinely
    /// means TMDB has none, which is the only case the hero holds back.
    private static func heroNeedsArtwork(backdropPath: String?, logoPath: String?, enrichedAt: Date?) -> Bool {
        guard (backdropPath ?? "").isEmpty || (logoPath ?? "").isEmpty else { return false }
        guard let enrichedAt else { return true }
        return Date().timeIntervalSince(enrichedAt) >= 14 * 24 * 3600
    }

    // MARK: - Watchlist

    /// Loads the connected user's Trakt watchlist and keeps only the titles the
    /// user actually owns in the active playlist — matched by TMDB id, the same
    /// way the trending rows work, and narrowed to the surface's medium.
    func loadWatchlist(cacheKey: String) async {
        if let cached = SectionFeedCache.shared.watchlistEntry(surface, for: cacheKey) {
            collections[.builtin(.traktWatchlist)] = cached
            return
        }
        guard let context else { return }
        guard TraktService.shared.isConnected else {
            collections[.builtin(.traktWatchlist)] = .empty
            return
        }
        let items = await TraktService.shared.fetchWatchlist()
        let entries = items.compactMap { item -> HomeListEntry? in
            switch item.type {
            case "movie":
                guard let media = item.movie, let tmdbId = media.ids.tmdb else { return nil }
                return HomeListEntry(tmdbId: tmdbId, mediaType: .movie, title: media.title ?? "")
            case "show":
                guard let media = item.show, let tmdbId = media.ids.tmdb else { return nil }
                return HomeListEntry(tmdbId: tmdbId, mediaType: .series, title: media.title ?? "")
            default:
                return nil
            }
        }
        let collection = makeCollection(entries: entries, context: context)
        collections[.builtin(.traktWatchlist)] = collection
        SectionFeedCache.shared.storeWatchlist(surface, key: cacheKey, collection: collection)
        await refreshHeroArtwork()
    }

    // MARK: - Custom sections

    /// Fetches every visible custom list concurrently, then resolves only its
    /// 20-card preview against the local catalog. The full lightweight source
    /// remains in the snapshot for later pages.
    func loadCustomSections(cacheKey: String, sections: [CustomHomeSection]) async {
        guard !sections.isEmpty else {
            replaceCustomCollections(with: [:])
            return
        }
        if let cached = SectionFeedCache.shared.customEntry(surface, for: cacheKey) {
            replaceCustomCollections(with: cached)
            // The memo retains both the lightweight source and resolved preview;
            // ImagePipeline remains responsible for artwork bytes.
            return
        }
        guard let context else { return }

        let interval = Perf.begin(.homeCustomSections)
        defer { Perf.end(interval) }

        let lists = await withTaskGroup(of: (UUID, [HomeListEntry]?).self) { group in
            for section in sections {
                group.addTask {
                    // A failed fetch is nil, not an empty list — the two are
                    // handled differently below.
                    await (section.id, try? HomeListCatalog.entries(for: section.sourceURL))
                }
            }
            var results: [UUID: [HomeListEntry]?] = [:]
            for await (id, entries) in group {
                results[id] = entries
            }
            return results
        }

        var resolved: [UUID: SectionCollectionSnapshot] = [:]
        for section in sections {
            resolved[section.id] = makeCollection(
                entries: (lists[section.id] ?? nil) ?? [],
                context: context
            )
        }
        replaceCustomCollections(with: resolved)
        await refreshHeroArtwork()

        // Only memo a complete pass. Caching a row that failed to load (offline
        // at launch, provider down) would leave it empty for the whole session,
        // since the cache key doesn't change until the catalog or the sections do.
        guard sections.allSatisfy({ (lists[$0.id] ?? nil) != nil }) else { return }
        SectionFeedCache.shared.storeCustom(surface, key: cacheKey, collections: resolved)
    }

    /// Fetches wide artwork for at most the carousel's eight visible candidates.
    /// The rest of the preview — and all retained source entries — remain plain
    /// catalog/list data until the user asks to see them.
    private func refreshHeroArtwork() async {
        guard let context, heroRef != nil else { return }
        let candidates = Array(heroCandidates.prefix(Self.heroLimit))
        guard !candidates.isEmpty else { return }
        await enrichHeroArtwork(candidates, context: context)
        // Enrichment saves on a background context; the merge back doesn't
        // reliably re-notify this surface, and the arrays haven't changed — only
        // the models they point at have. Bump so `heroItems` recomputes.
        heroArtworkRevision &+= 1
    }

    // MARK: - Context plumbing

    /// Set by the surface before each load. Held rather than passed to every
    /// call so the `.task` sites stay as short as they were when this logic
    /// lived on `HomeView`.
    private var context: Context?

    func update(context: Context) {
        self.context = context
    }

    private func makeCollection(
        entries: [HomeListEntry],
        context: Context
    ) -> SectionCollectionSnapshot {
        SectionCollectionResolver.snapshot(
            entries: entries,
            mediaType: surface.mediaType,
            context: context,
            previewLimit: Self.itemLimit
        )
    }

    private func replaceCustomCollections(with custom: [UUID: SectionCollectionSnapshot]) {
        collections = collections.filter { key, _ in
            if case .custom = key { return false }
            return true
        }
        for (id, collection) in custom {
            collections[.custom(id)] = collection
        }
    }
}

// MARK: - Load state

enum HomeLoadState {
    case idle
    case loading
    case loaded
    case failed

    var isSettled: Bool {
        switch self {
        case .idle, .loading: false
        case .loaded, .failed: true
        }
    }
}

/// `tmdbId` is optional, and neither `?? -1` (TERNARY) nor a nil-check +
/// force-unwrap (ForcedUnwrap) survives SwiftData's SQL generation — both throw
/// at fetch time on a real store (in-memory stores skip SQL and don't
/// reproduce it). Comparing against a `Set<Int?>` builds a plain `IN` clause.
/// Internal (not fileprivate) so tests can run them against a SQLite store.
nonisolated func movieTmdbIdPredicate(ids: Set<Int>) -> Predicate<Movie> {
    let optionalIds = Set(ids.map(Int?.some))
    return #Predicate { optionalIds.contains($0.tmdbId) }
}

nonisolated func seriesTmdbIdPredicate(ids: Set<Int>) -> Predicate<Series> {
    let optionalIds = Set(ids.map(Int?.some))
    return #Predicate { optionalIds.contains($0.tmdbId) }
}

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

    private(set) var heroItems: [HeroItem] = []
    private(set) var trendingMovies: [HomeMediaItem] = []
    private(set) var trendingSeries: [HomeMediaItem] = []
    private(set) var watchlist: [HomeMediaItem] = []
    private(set) var customItems: [UUID: [HomeMediaItem]] = [:]
    private(set) var trendingState: HomeLoadState = .idle

    /// How many matched titles a remote-backed row shows.
    static let itemLimit = 20
    /// How many hero candidates the Home carousel pages through.
    private static let heroLimit = 8

    init(surface: SectionSurface) {
        self.surface = surface
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
            heroItems = cached.heroes
            trendingMovies = cached.movies
            trendingSeries = cached.series
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

            let matched = matchTrending(movies: movies, tvSeries: tvSeries, context: context)
            trendingMovies = Array(matched.movies.prefix(Self.itemLimit))
            trendingSeries = Array(matched.series.prefix(Self.itemLimit))
            // Only Home has a hero carousel.
            heroItems = surface == .home ? Array(matched.heroes.prefix(Self.heroLimit)) : []
            trendingState = .loaded
            SectionFeedCache.shared.storeTrending(surface, key: cacheKey, entry: .init(
                heroes: heroItems, movies: trendingMovies, series: trendingSeries
            ))
            await enrichHeroLogos(context: context)
        } catch {
            trendingState = .failed
        }
    }

    /// Matches the trending titles against the local catalog (two batched
    /// queries instead of one indexed fetch per title) and interleaves the
    /// hero candidates.
    private func matchTrending(
        movies: [TrendingTitle],
        tvSeries: [TrendingTitle],
        context: Context
    ) -> (movies: [HomeMediaItem], series: [HomeMediaItem], heroes: [HeroItem]) {
        let moviesByTmdbId = fetchMovies(tmdbIds: movies.map(\.id), context: context)
        let seriesByTmdbId = fetchSeries(tmdbIds: tvSeries.map(\.id), context: context)

        var movieItems: [HomeMediaItem] = []
        var seriesItems: [HomeMediaItem] = []
        var heroes: [HeroItem] = []
        let maxCount = max(movies.count, tvSeries.count)
        for index in 0 ..< maxCount {
            if index < movies.count {
                let title = movies[index]
                if let movie = moviesByTmdbId[title.id] {
                    movieItems.append(.movie(movie))
                    heroes.append(.movie(
                        movie,
                        backdropURL: TMDBClient.backdropURL(title.backdropPath),
                        overview: title.overview
                    ))
                }
            }
            if index < tvSeries.count {
                let title = tvSeries[index]
                if let series = seriesByTmdbId[title.id] {
                    seriesItems.append(.series(series))
                    heroes.append(.series(
                        series,
                        backdropURL: TMDBClient.backdropURL(title.backdropPath),
                        overview: title.overview
                    ))
                }
            }
        }
        return (movieItems, seriesItems, heroes)
    }

    /// The TMDB trending feed carries no logo artwork, so a hero title shows
    /// only its backdrop until its full details are fetched. That fetch used to
    /// happen only on the detail screen, so logos "popped in" after visiting
    /// Details and coming back. Enrich the visible hero titles up front via the
    /// same TMDB detail path. Runs after the carousel is shown so backdrops
    /// aren't blocked.
    private func enrichHeroLogos(context: Context) async {
        guard !heroItems.isEmpty else { return }
        // Enrich on the manager's background context; the saves auto-merge back
        // so the hero models pick up their logos without a main-thread store
        // write blocking the carousel.
        let manager = ContentSyncManager(modelContainer: context.modelContext.container)
        for hero in heroItems {
            switch hero {
            case let .movie(movie, _, _):
                guard Self.heroNeedsLogo(logoPath: movie.logoPath, enrichedAt: movie.tmdbEnrichedAt),
                      let tmdbId = movie.tmdbId
                else { continue }
                await manager.enrichMovie(id: movie.id, tmdbId: tmdbId)
            case let .series(series, _, _):
                guard Self.heroNeedsLogo(logoPath: series.logoPath, enrichedAt: series.tmdbEnrichedAt),
                      let tmdbId = series.tmdbId
                else { continue }
                await manager.enrichSeries(id: series.id, tmdbId: tmdbId)
            }
        }
    }

    /// A hero needs a logo fetch when it has none yet and hasn't been enriched
    /// recently. The recency guard mirrors the detail screen's 14-day window so
    /// titles TMDB simply has no logo for aren't refetched on every appearance.
    private static func heroNeedsLogo(logoPath: String?, enrichedAt: Date?) -> Bool {
        guard (logoPath ?? "").isEmpty else { return false }
        guard let enrichedAt else { return true }
        return Date().timeIntervalSince(enrichedAt) >= 14 * 24 * 3600
    }

    // MARK: - Watchlist

    /// Loads the connected user's Trakt watchlist and keeps only the titles the
    /// user actually owns in the active playlist — matched by TMDB id, the same
    /// way the trending rows work, and narrowed to the surface's medium.
    func loadWatchlist(cacheKey: String) async {
        if let cached = SectionFeedCache.shared.watchlistEntry(surface, for: cacheKey) {
            watchlist = cached
            return
        }
        guard let context else { return }
        guard TraktService.shared.isConnected else {
            watchlist = []
            return
        }
        let items = await TraktService.shared.fetchWatchlist()
        let wantsMovies = surface.mediaType != .series
        let wantsSeries = surface.mediaType != .movie
        let moviesByTmdbId = wantsMovies
            ? fetchMovies(tmdbIds: items.compactMap { $0.movie?.ids.tmdb }, context: context)
            : [:]
        let seriesByTmdbId = wantsSeries
            ? fetchSeries(tmdbIds: items.compactMap { $0.show?.ids.tmdb }, context: context)
            : [:]
        var matched: [HomeMediaItem] = []
        for item in items {
            switch item.type {
            case "movie":
                if wantsMovies, let tmdbID = item.movie?.ids.tmdb, let movie = moviesByTmdbId[tmdbID] {
                    matched.append(.movie(movie))
                }
            case "show":
                if wantsSeries, let tmdbID = item.show?.ids.tmdb, let series = seriesByTmdbId[tmdbID] {
                    matched.append(.series(series))
                }
            default:
                break
            }
        }
        watchlist = Array(matched.prefix(Self.itemLimit))
        SectionFeedCache.shared.storeWatchlist(surface, key: cacheKey, items: watchlist)
    }

    // MARK: - Custom sections

    /// Fetches every visible custom list concurrently, then matches each one
    /// against the local catalog. The fetches are the slow part and are
    /// independent; the matching is two batched queries per section and stays
    /// on the main actor with the rest of the surface's model access.
    func loadCustomSections(cacheKey: String, sections: [CustomHomeSection]) async {
        guard !sections.isEmpty else {
            customItems = [:]
            return
        }
        if let cached = SectionFeedCache.shared.customEntry(surface, for: cacheKey) {
            customItems = cached
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

        var matched: [UUID: [HomeMediaItem]] = [:]
        for section in sections {
            matched[section.id] = match(entries: (lists[section.id] ?? nil) ?? [], context: context)
        }
        customItems = matched

        // Only memo a complete pass. Caching a row that failed to load (offline
        // at launch, provider down) would leave it empty for the whole session,
        // since the cache key doesn't change until the catalog or the sections do.
        guard sections.allSatisfy({ (lists[$0.id] ?? nil) != nil }) else { return }
        SectionFeedCache.shared.storeCustom(surface, key: cacheKey, items: matched)
    }

    /// Resolves list entries to local models, preserving the list's own order,
    /// dropping anything the active playlist doesn't carry, and — on a scoped
    /// surface — anything of the wrong medium.
    private func match(entries: [HomeListEntry], context: Context) -> [HomeMediaItem] {
        let wanted = entries.filter { surface.mediaType == nil || $0.mediaType == surface.mediaType }
        guard !wanted.isEmpty else { return [] }
        let moviesByTmdbId = fetchMovies(
            tmdbIds: wanted.filter { $0.mediaType == .movie }.map(\.tmdbId), context: context
        )
        let seriesByTmdbId = fetchSeries(
            tmdbIds: wanted.filter { $0.mediaType == .series }.map(\.tmdbId), context: context
        )

        var items: [HomeMediaItem] = []
        var seen = Set<String>()
        for entry in wanted {
            let item: HomeMediaItem? = switch entry.mediaType {
            case .movie: moviesByTmdbId[entry.tmdbId].map(HomeMediaItem.movie)
            case .series: seriesByTmdbId[entry.tmdbId].map(HomeMediaItem.series)
            }
            // A list can name the same title twice (or a title can sit in the
            // catalog under two ids); keep the first placement.
            guard let item, seen.insert(item.id).inserted else { continue }
            items.append(item)
            if items.count >= Self.itemLimit { break }
        }
        return items
    }

    // MARK: - Context plumbing

    /// Set by the surface before each load. Held rather than passed to every
    /// call so the `.task` sites stay as short as they were when this logic
    /// lived on `HomeView`.
    private var context: Context?

    func update(context: Context) {
        self.context = context
    }

    // MARK: - Batched catalog lookup

    /// All active-playlist catalog matches for the given TMDB ids from one
    /// query, keyed by id. The per-title variant this replaces issued one fetch
    /// per trending/watchlist row — hundreds of sequential main-context
    /// round-trips on every load.
    private func fetchMovies(tmdbIds: [Int], context: Context) -> [Int: Movie] {
        let ids = Set(tmdbIds)
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Movie>(predicate: movieTmdbIdPredicate(ids: ids))
        var byId: [Int: Movie] = [:]
        for movie in (try? context.modelContext.fetch(descriptor)) ?? []
            where context.belongsToActivePlaylist(movie.id) && !context.restriction.hides(categoryID: movie.categoryId)
        {
            guard let tmdbId = movie.tmdbId, byId[tmdbId] == nil else { continue }
            byId[tmdbId] = movie
        }
        return byId
    }

    private func fetchSeries(tmdbIds: [Int], context: Context) -> [Int: Series] {
        let ids = Set(tmdbIds)
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Series>(predicate: seriesTmdbIdPredicate(ids: ids))
        var byId: [Int: Series] = [:]
        for series in (try? context.modelContext.fetch(descriptor)) ?? []
            where context.belongsToActivePlaylist(series.id) && !context.restriction.hides(categoryID: series.categoryId)
        {
            guard let tmdbId = series.tmdbId, byId[tmdbId] == nil else { continue }
            byId[tmdbId] = series
        }
        return byId
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

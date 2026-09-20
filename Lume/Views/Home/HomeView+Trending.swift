//
//  HomeView+Trending.swift
//  Lume
//
//  Home's TMDB trending and Trakt watchlist loading, split from `HomeView` to
//  keep the view file within size limits. Trending/watchlist titles are matched
//  against the local catalog in batched queries keyed by `tmdbId`.
//

import SwiftData
import SwiftUI

extension HomeView {
    private enum CacheRestore {
        case missing
        case stale
        case fresh
    }

    // MARK: - Trending

    func loadTrending(cacheKey: String) async {
        guard cacheKey == trendingKey else { return }
        let requestID = remoteLoadGate.begin(.trending)

        // Session cache: the tab's view (and this state) is torn down on every
        // tvOS tab switch; a matching cache entry restores the hero carousel
        // instantly instead of refetching TMDB and popping in again. A stale
        // entry still paints the first frame, but continues to revalidate.
        let cached = restoreTrending(for: cacheKey)
        if cached == .fresh { return }
        let client = TMDBClient.shared
        guard client.isConfigured else {
            if cached == .missing { trendingState = .loaded }
            return
        }
        if cached == .missing { trendingState = .loading }
        let interval = Perf.begin(.homeTrendingLoad)
        defer { Perf.end(interval) }
        do {
            async let movieTitles = client.trending(.movie)
            async let tvTitles = client.trending(.tvShow)
            let (movies, tvSeries) = try await (movieTitles, tvTitles)
            guard isCurrentTrendingRequest(requestID, cacheKey: cacheKey) else { return }

            let (movieItems, seriesItems, heroes) = matchTrending(movies: movies, tvSeries: tvSeries)
            let nextMovies = Array(movieItems.prefix(20))
            let nextSeries = Array(seriesItems.prefix(20))
            let nextHeroes = Array(heroes.prefix(8))
            guard isCurrentTrendingRequest(requestID, cacheKey: cacheKey) else { return }
            trendingMovies = nextMovies
            trendingSeries = nextSeries
            heroItems = nextHeroes
            trendingState = .loaded
            HomeTrendingCache.shared.storeTrending(
                key: cacheKey, heroes: nextHeroes, movies: nextMovies, series: nextSeries
            )
            await enrichHeroLogos()
        } catch {
            guard isCurrentTrendingRequest(requestID, cacheKey: cacheKey) else { return }
            if cached == .missing { trendingState = .failed }
        }
    }

    private func restoreTrending(for cacheKey: String) -> CacheRestore {
        guard let cached = HomeTrendingCache.shared.trendingEntry(for: cacheKey) else { return .missing }
        heroItems = cached.value.heroes
        trendingMovies = cached.value.movies
        trendingSeries = cached.value.series
        trendingState = .loaded
        return cached.isFresh ? .fresh : .stale
    }

    private func isCurrentTrendingRequest(_ id: UUID, cacheKey: String) -> Bool {
        !Task.isCancelled
            && cacheKey == trendingKey
            && remoteLoadGate.isCurrent(id, for: .trending)
    }

    /// Matches the trending titles against the local catalog (two batched
    /// queries instead of one indexed fetch per title) and interleaves the
    /// hero candidates.
    private func matchTrending(
        movies: [TrendingTitle],
        tvSeries: [TrendingTitle]
    ) -> (movies: [HomeMediaItem], series: [HomeMediaItem], heroes: [HeroItem]) {
        let moviesByTmdbId = fetchMovies(tmdbIds: movies.map(\.id))
        let seriesByTmdbId = fetchSeries(tmdbIds: tvSeries.map(\.id))

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
    private func enrichHeroLogos() async {
        // Enrich on the manager's background context; the saves auto-merge back
        // so the hero models pick up their logos without a main-thread store
        // write blocking the carousel.
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        for hero in heroItems {
            switch hero {
            case let .movie(movie, _, _):
                guard heroNeedsLogo(logoPath: movie.logoPath, enrichedAt: movie.tmdbEnrichedAt),
                      let tmdbId = movie.tmdbId
                else { continue }
                await manager.enrichMovie(id: movie.id, tmdbId: tmdbId)
            case let .series(series, _, _):
                guard heroNeedsLogo(logoPath: series.logoPath, enrichedAt: series.tmdbEnrichedAt),
                      let tmdbId = series.tmdbId
                else { continue }
                await manager.enrichSeries(id: series.id, tmdbId: tmdbId)
            }
        }
    }

    /// A hero needs a logo fetch when it has none yet and hasn't been enriched
    /// recently. The recency guard mirrors the detail screen's 14-day window so
    /// titles TMDB simply has no logo for aren't refetched on every appearance.
    private func heroNeedsLogo(logoPath: String?, enrichedAt: Date?) -> Bool {
        guard (logoPath ?? "").isEmpty else { return false }
        guard let enrichedAt else { return true }
        return Date().timeIntervalSince(enrichedAt) >= 14 * 24 * 3600
    }

    // MARK: - Watchlist

    /// Loads the connected user's Trakt watchlist and keeps only the titles the
    /// user actually owns in the active playlist — matched by TMDB id, the same
    /// way the trending rows work.
    func loadWatchlist(cacheKey: String) async {
        guard cacheKey == watchlistKey else { return }
        let requestID = remoteLoadGate.begin(.watchlist)

        let cached = restoreWatchlist(for: cacheKey)
        if cached == .fresh { return }
        guard trakt.isConnected else {
            watchlist = []
            return
        }
        do {
            let items = try await trakt.watchlistItems()
            guard isCurrentWatchlistRequest(requestID, cacheKey: cacheKey) else { return }
            let moviesByTmdbId = fetchMovies(tmdbIds: items.compactMap { $0.movie?.ids.tmdb })
            let seriesByTmdbId = fetchSeries(tmdbIds: items.compactMap { $0.show?.ids.tmdb })
            let matched = matchWatchlist(items, moviesByTmdbId: moviesByTmdbId, seriesByTmdbId: seriesByTmdbId)
            let nextWatchlist = Array(matched.prefix(20))
            guard isCurrentWatchlistRequest(requestID, cacheKey: cacheKey) else { return }
            watchlist = nextWatchlist
            HomeTrendingCache.shared.storeWatchlist(key: cacheKey, items: nextWatchlist)
        } catch {
            // A failed revalidation must not turn a usable stale row into an
            // authoritative empty result. The next appearance can retry.
            if cached == .missing, isCurrentWatchlistRequest(requestID, cacheKey: cacheKey) {
                watchlist = []
            }
        }
    }

    private func restoreWatchlist(for cacheKey: String) -> CacheRestore {
        guard let cached = HomeTrendingCache.shared.watchlistEntry(for: cacheKey) else { return .missing }
        watchlist = cached.value
        return cached.isFresh ? .fresh : .stale
    }

    private func matchWatchlist(
        _ items: [TraktWatchlistItem],
        moviesByTmdbId: [Int: Movie],
        seriesByTmdbId: [Int: Series]
    ) -> [HomeMediaItem] {
        items.compactMap { item in
            switch item.type {
            case "movie":
                guard let tmdbID = item.movie?.ids.tmdb, let movie = moviesByTmdbId[tmdbID] else { return nil }
                return .movie(movie)
            case "show":
                guard let tmdbID = item.show?.ids.tmdb, let series = seriesByTmdbId[tmdbID] else { return nil }
                return .series(series)
            default:
                return nil
            }
        }
    }

    private func isCurrentWatchlistRequest(_ id: UUID, cacheKey: String) -> Bool {
        !Task.isCancelled
            && cacheKey == watchlistKey
            && remoteLoadGate.isCurrent(id, for: .watchlist)
    }

    // MARK: - Batched catalog lookup

    /// All active-playlist catalog matches for the given TMDB ids from one
    /// query, keyed by id. The per-title variant this replaces issued one fetch
    /// per trending/watchlist row — hundreds of sequential main-context
    /// round-trips on every Home load.
    private func fetchMovies(tmdbIds: [Int]) -> [Int: Movie] {
        let ids = Set(tmdbIds)
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Movie>(predicate: movieTmdbIdPredicate(ids: ids))
        var byId: [Int: Movie] = [:]
        for movie in (try? modelContext.fetch(descriptor)) ?? []
            where belongsToActivePlaylist(movie.id) && !restriction.hides(categoryID: movie.categoryId)
        {
            guard let tmdbId = movie.tmdbId, byId[tmdbId] == nil else { continue }
            byId[tmdbId] = movie
        }
        return byId
    }

    private func fetchSeries(tmdbIds: [Int]) -> [Int: Series] {
        let ids = Set(tmdbIds)
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Series>(predicate: seriesTmdbIdPredicate(ids: ids))
        var byId: [Int: Series] = [:]
        for series in (try? modelContext.fetch(descriptor)) ?? []
            where belongsToActivePlaylist(series.id) && !restriction.hides(categoryID: series.categoryId)
        {
            guard let tmdbId = series.tmdbId, byId[tmdbId] == nil else { continue }
            byId[tmdbId] = series
        }
        return byId
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

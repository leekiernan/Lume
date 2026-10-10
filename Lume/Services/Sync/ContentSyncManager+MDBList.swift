import Foundation
import SwiftData

// MARK: - MDBList Ratings Enrichment

extension ContentSyncManager {
    /// Fetches aggregator ratings (IMDb / Rotten Tomatoes / Metacritic / Trakt /
    /// Letterboxd / TMDB) for a TMDB id without persisting: the proxy's when it
    /// advertises fresh ones, else MDBList directly. The caller applies the data
    /// to its own context to avoid cross-context merge timing issues. Nil when
    /// neither source has ratings.
    func fetchTitleRatings(tmdbId: Int, type: LumeMetadataKind, releaseDate: String?, contentID: String) async throws -> LumeTitleRatings? {
        let source = LumeProxySource.snapshot(contentID: contentID, in: ModelContext(modelContainer))
        return try await LumeTitleMetadataRouter().ratings(id: tmdbId, type: type, releaseDate: releaseDate, source: source)
    }

    /// Fetches and persists ratings for a movie **off the main thread**, on the
    /// engine actor's own background context (the save auto-merges into the
    /// main context). Keeps the rating write off a detail view's hot path. The
    /// stamp is when the ratings were fetched at their source, so proxy ratings
    /// age from the proxy's lookup, not from this read.
    func enrichMovieRatings(movieId: String, tmdbId: Int, releaseDate: String?) async {
        guard let ratings = try? await fetchTitleRatings(tmdbId: tmdbId, type: .movie, releaseDate: releaseDate, contentID: movieId) else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == movieId })
        descriptor.fetchLimit = 1
        guard let movie = try? context.fetch(descriptor).first, movie.tmdbId == tmdbId else { return }
        movie.externalRatings = ratings.ratings
        movie.ratingsEnrichedAt = ratings.fetchedAt
        try? context.save()
    }

    /// Series counterpart of ``enrichMovieRatings(movieId:tmdbId:releaseDate:)``.
    func enrichSeriesRatings(seriesId: String, tmdbId: Int, releaseDate: String?) async {
        guard let ratings = try? await fetchTitleRatings(tmdbId: tmdbId, type: .series, releaseDate: releaseDate, contentID: seriesId) else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == seriesId })
        descriptor.fetchLimit = 1
        guard let series = try? context.fetch(descriptor).first, series.tmdbId == tmdbId else { return }
        series.externalRatings = ratings.ratings
        series.ratingsEnrichedAt = ratings.fetchedAt
        try? context.save()
    }
}

// MARK: - Detail-screen enrichment

/// Fetches ratings for a movie and persists them, keyed directly by the TMDB
/// id we already store. No-ops when the TMDB id is missing, no source can
/// supply ratings (no proxy, no MDBList key), or they are still fresh for the
/// title's age (see ``RatingsFreshness``). Call from a detail view's `.task`
/// after TMDB enrichment.
@MainActor
func enrichMovieRatingsIfNeeded(_ movie: Movie, context: ModelContext) async {
    guard let tmdbId = movie.tmdbId, !RatingsFreshness.isFresh(movie.ratingsEnrichedAt, releaseDate: movie.releaseDate),
          LumeTitleMetadataRouter().canFetchRatings(source: LumeProxySource.snapshot(contentID: movie.id, in: context)) else { return }
    // Fetch + persist on the manager's background context (off the main thread);
    // the save auto-merges back so `movie.externalRatings` updates in the view.
    let manager = ContentSyncManager(modelContainer: context.container)
    await manager.enrichMovieRatings(movieId: movie.id, tmdbId: tmdbId, releaseDate: movie.releaseDate)
}

/// Series counterpart of ``enrichMovieRatingsIfNeeded(_:context:)``.
@MainActor
func enrichSeriesRatingsIfNeeded(_ series: Series, context: ModelContext) async {
    guard let tmdbId = series.tmdbId, !RatingsFreshness.isFresh(series.ratingsEnrichedAt, releaseDate: series.releaseDate),
          LumeTitleMetadataRouter().canFetchRatings(source: LumeProxySource.snapshot(contentID: series.id, in: context)) else { return }
    let manager = ContentSyncManager(modelContainer: context.container)
    await manager.enrichSeriesRatings(seriesId: series.id, tmdbId: tmdbId, releaseDate: series.releaseDate)
}

import Foundation
import SwiftData

// MARK: - TMDB Enrichment

extension ContentSyncManager {
    /// Fetches TMDB movie details without persisting. The caller applies
    /// the data directly to its own context to avoid cross-context merge
    /// timing issues.
    func fetchTMDBMovieDetails(tmdbId: Int) async throws -> TMDBTitleDetails? {
        let client = TMDBClient.shared
        guard client.isConfigured else { return nil }
        return try await client.movieDetails(tmdbId)
    }

    /// Fetches TMDB TV series details without persisting.
    func fetchTMDBTVDetails(tmdbId: Int) async throws -> TMDBTitleDetails? {
        let client = TMDBClient.shared
        guard client.isConfigured else { return nil }
        return try await client.tvDetails(tmdbId)
    }

    /// Background scalar enrichment for heroes/rails. Cast relationships remain
    /// owned by the detail context; values returned here can render immediately
    /// even when the view context has not merged the background save yet.
    @discardableResult
    func enrichMovieArtwork(id: String, tmdbId: Int) async -> TMDBTitleDetails? {
        guard let details = try? await fetchTMDBMovieDetails(tmdbId: tmdbId), !Task.isCancelled else { return nil }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let movie = try? context.fetch(descriptor).first else { return nil }
        applyMovieArtwork(details, to: movie)
        try? context.save()
        return details
    }

    /// Series counterpart of ``enrichMovieArtwork(id:tmdbId:)``.
    @discardableResult
    func enrichSeriesArtwork(id: String, tmdbId: Int) async -> TMDBTitleDetails? {
        guard let details = try? await fetchTMDBTVDetails(tmdbId: tmdbId), !Task.isCancelled else { return nil }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let series = try? context.fetch(descriptor).first else { return nil }
        applySeriesArtwork(details, to: series)
        try? context.save()
        return details
    }

    /// Fetches the list of TMDB movie IDs that belong to a collection.
    func fetchTMDBCollectionMovieIDs(collectionId: Int) async throws -> [Int] {
        let client = TMDBClient.shared
        guard client.isConfigured else { return [] }
        return try await client.collectionMovieIDs(collectionId)
    }
}

// MARK: - Context apply

/// Scalar metadata/artwork only: safe for background enrichment while a
/// detail screen holds cast faults. Does not claim full-detail freshness.
nonisolated func applyMovieArtwork(_ details: TMDBTitleDetails, to movie: Movie) {
    movie.backdropPath = details.backdropPath ?? movie.backdropPath
    movie.posterPath = details.posterPath ?? movie.posterPath
    movie.posterCheckedAt = Date()
    movie.logoPath = details.logoPath ?? movie.logoPath
    movie.tagline = details.tagline ?? movie.tagline
    movie.contentRating = details.contentRating ?? movie.contentRating
    movie.imdbId = details.imdbId ?? movie.imdbId
    movie.similarTitleIds = details.similarIDs
    movie.trailers = details.videos

    if (movie.plot ?? "").isEmpty, let overview = details.overview {
        movie.plot = overview
    }
    // TMDB is the primary genre source: its normalized genre names overwrite any
    // provider-supplied genre once enrichment runs. The provider value is only a
    // fallback shown until then (see `applySeriesFields`; VOD lists carry no genre).
    if !details.genreNames.isEmpty {
        movie.genre = details.genreNames.joined(separator: ", ")
    }
    if (movie.durationSecs ?? 0) == 0, let mins = details.runtimeMinutes, mins > 0 {
        movie.durationSecs = mins * 60
    }
    if movie.rating == 0, let vote = details.voteAverage, vote > 0 {
        movie.rating = vote
    }

    if let collectionId = details.collectionId, collectionId > 0 {
        movie.collectionId = collectionId
        movie.collectionName = details.collectionName
        movie.collectionPosterPath = details.collectionPosterPath
        movie.collectionBackdropPath = details.collectionBackdropPath
    }
    movie.tmdbArtworkEnrichedAt = Date()
}

/// Full-detail enrichment on the context that owns the displayed cast. Never
/// call this from an artwork/indexing background context: replacing cast rows
/// there can invalidate faults retained by a detail screen before they merge.
nonisolated func applyMovieDetails(_ details: TMDBTitleDetails, to movie: Movie, context: ModelContext) {
    applyMovieArtwork(details, to: movie)
    replaceCast(of: movie.castMembers, with: details.cast, ownerId: movie.id, context: context) { castMember in
        castMember.movie = movie
    }
    movie.tmdbEnrichedAt = Date()
}

/// Scalar metadata/artwork only: safe for background enrichment while a
/// detail screen holds cast faults. Does not claim full-detail freshness.
nonisolated func applySeriesArtwork(_ details: TMDBTitleDetails, to series: Series) {
    series.backdropPath = details.backdropPath ?? series.backdropPath
    series.posterPath = details.posterPath ?? series.posterPath
    series.posterCheckedAt = Date()
    series.logoPath = details.logoPath ?? series.logoPath
    series.tagline = details.tagline ?? series.tagline
    series.contentRating = details.contentRating ?? series.contentRating
    series.imdbId = details.imdbId ?? series.imdbId
    series.similarTitleIds = details.similarIDs
    series.trailers = details.videos

    if (series.plot ?? "").isEmpty, let overview = details.overview {
        series.plot = overview
    }
    // TMDB is the primary genre source: it overwrites the provider genre seeded
    // at sync (see `applySeriesFields`), which serves only as the fallback.
    if !details.genreNames.isEmpty {
        series.genre = details.genreNames.joined(separator: ", ")
    }
    if (series.cast ?? "").isEmpty, !details.cast.isEmpty {
        series.cast = details.cast.prefix(6).map(\.name).joined(separator: ", ")
    }
    let currentRating = series.rating.flatMap(Double.init) ?? 0
    if currentRating == 0, let vote = details.voteAverage, vote > 0 {
        series.rating = String(format: "%.1f", vote)
    }
    series.tmdbArtworkEnrichedAt = Date()
}

/// Full-detail enrichment on the context that owns the displayed cast. Never
/// call this from an artwork/indexing background context: replacing cast rows
/// there can invalidate faults retained by a detail screen before they merge.
nonisolated func applySeriesDetails(_ details: TMDBTitleDetails, to series: Series, context: ModelContext) {
    applySeriesArtwork(details, to: series)
    replaceCast(of: series.castMembers, with: details.cast, ownerId: series.id, context: context) { castMember in
        castMember.series = series
    }
    series.tmdbEnrichedAt = Date()
}

// MARK: - Cast helpers

/// Deletes the existing cast for a title and inserts the fresh TMDB billing,
/// wiring each new member to its owner via `assign`.
private nonisolated func replaceCast(
    of existing: [CastMember],
    with cast: [TMDBCastMember],
    ownerId: String,
    context: ModelContext,
    assign: (CastMember) -> Void
) {
    for member in existing {
        context.delete(member)
    }
    for member in cast {
        let castMember = CastMember(
            id: "\(ownerId)-cast-\(member.order)-\(member.tmdbPersonId)",
            tmdbPersonId: member.tmdbPersonId,
            name: member.name,
            role: member.character,
            profilePath: member.profilePath,
            order: member.order
        )
        context.insert(castMember)
        assign(castMember)
    }
}

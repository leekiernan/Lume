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
        return persistArtwork(details, descriptor: FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id }), apply: applyMovieArtwork)
    }

    /// Series counterpart of ``enrichMovieArtwork(id:tmdbId:)``.
    @discardableResult
    func enrichSeriesArtwork(id: String, tmdbId: Int) async -> TMDBTitleDetails? {
        guard let details = try? await fetchTMDBTVDetails(tmdbId: tmdbId), !Task.isCancelled else { return nil }
        return persistArtwork(details, descriptor: FetchDescriptor<Series>(predicate: #Predicate { $0.id == id }), apply: applySeriesArtwork)
    }

    /// The network await is over before creating this context. Scalar appliers
    /// are explicit; no generic path can accidentally replace cast relationships.
    private func persistArtwork<Row: PersistentModel>(
        _ details: TMDBTitleDetails, descriptor: FetchDescriptor<Row>, apply: (TMDBTitleDetails, Row) -> Void
    ) -> TMDBTitleDetails? {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return nil }
        apply(details, row)
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
    movie.applyCommonArtwork(details)
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
    series.applyCommonArtwork(details)
    if (series.cast ?? "").isEmpty, !details.cast.isEmpty {
        series.cast = details.cast.prefix(6).map(\.name).joined(separator: ", ")
    }
    let currentRating = series.rating.flatMap(Double.init) ?? 0
    if currentRating == 0, let vote = details.voteAverage, vote > 0 {
        series.rating = String(format: "%.1f", vote)
    }
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

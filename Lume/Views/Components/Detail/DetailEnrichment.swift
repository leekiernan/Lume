//
//  DetailEnrichment.swift
//  Lume
//
//  The TMDB detail enrichment every movie / series detail screen runs on
//  appear (iOS, macOS and tvOS), plus the freshness window that decides
//  whether a title needs it.
//

import Foundation
import SwiftData

nonisolated enum TMDBFreshness {
    /// How long a title's TMDB enrichment stays fresh. Revisits inside the
    /// window skip the fetch; it also stops the hero carousel from repeatedly
    /// asking TMDB for artwork it does not have.
    static let window: TimeInterval = 14 * 24 * 3600

    /// Whether a title stamped at `enrichedAt` is still inside the window.
    /// A never-enriched title (`nil`) is stale.
    static func isFresh(_ enrichedAt: Date?, now: Date = Date()) -> Bool {
        guard let enrichedAt else { return false }
        return now.timeIntervalSince(enrichedAt) < window
    }
}

/// Whether a detail screen should show its loading state and fetch TMDB
/// details: the title is matched, TMDB is configured, and the stamp is stale.
func detailNeedsTMDBFetch(tmdbId: Int?, enrichedAt: Date?) -> Bool {
    tmdbId != nil && TMDBClient.shared.isConfigured && !TMDBFreshness.isFresh(enrichedAt)
}

/// Fetches TMDB movie details off-thread, then applies them on the view's own
/// context. Cast replacement must stay on the context displaying those rows;
/// doing it elsewhere can invalidate retained faults before they merge.
/// Background artwork enrichment is scalar-only and does not mark these
/// complete details fresh, so it cannot suppress this full enrichment.
///
/// - Returns: whether details were applied (callers bump their refresh token).
@discardableResult
func enrichMovieDetailsIfNeeded(_ movie: Movie, context: ModelContext) async -> Bool {
    guard let tmdbId = movie.tmdbId, !TMDBFreshness.isFresh(movie.tmdbEnrichedAt) else { return false }
    let manager = ContentSyncManager(modelContainer: context.container)
    guard let details = try? await manager.fetchTMDBMovieDetails(tmdbId: tmdbId), !Task.isCancelled else { return false }
    applyMovieDetails(details, to: movie, context: context)
    try? context.save()
    return true
}

/// Series counterpart of ``enrichMovieDetailsIfNeeded(_:context:)``.
@discardableResult
func enrichSeriesDetailsIfNeeded(_ series: Series, context: ModelContext) async -> Bool {
    guard let tmdbId = series.tmdbId, !TMDBFreshness.isFresh(series.tmdbEnrichedAt) else { return false }
    let manager = ContentSyncManager(modelContainer: context.container)
    guard let details = try? await manager.fetchTMDBTVDetails(tmdbId: tmdbId), !Task.isCancelled else { return false }
    applySeriesDetails(details, to: series, context: context)
    try? context.save()
    return true
}

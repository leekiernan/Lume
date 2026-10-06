import Foundation
import OSLog
import SwiftData

/// Scalar-only poster recovery. Reads a fresh context before asking TMDB;
/// never replaces cast, watch progress or full-detail freshness stamps.
actor PosterArtworkRecovery {
    private let container: ModelContainer
    init(container: ModelContainer) {
        self.container = container
    }

    /// Playback is already authorized by the player host. Resolve its portrait
    /// independently of card/rail lifetimes, through the same bounded recovery
    /// queue and scalar persistence path used by library cards.
    func playbackPoster(for reference: PlayableMedia.ContentRef, profile: UUID?) async -> URL? {
        guard !Task.isCancelled, profile == ActiveProfileStore.current else { return nil }
        guard let source = playbackSource(for: reference) else {
            Logger.network.notice("Playback portrait unavailable: catalog owner missing")
            return nil
        }
        if let url = source.url { return url }
        let key = PosterEnrichmentQueue.Key(catalog: ObjectIdentifier(container), request: source.request,
                                            profile: profile, visibility: "authorizedPlayback")
        let result = await PosterEnrichmentQueue.shared.lookup(key) {
            try await self.lookup(source.request, profile: profile, restriction: ContentRestriction())
        }
        guard !Task.isCancelled, profile == ActiveProfileStore.current else { return nil }
        return TMDBArtworkURL.poster(result?.path)
    }

    nonisolated struct PlaybackSource {
        let request: PosterArtworkRequest
        let url: URL?
    }

    /// Fresh actor-owned reads also see posters enriched after the immutable
    /// PlayableMedia snapshot was created (e.g. synced Continue Watching).
    func playbackSource(for reference: PlayableMedia.ContentRef) -> PlaybackSource? {
        let context = ModelContext(container)
        switch reference {
        case let .movie(id):
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let movie = try? context.fetch(descriptor).first else { return nil }
            return PlaybackSource(request: .init(kind: .movie, id: movie.id, categoryID: movie.categoryId),
                                  url: Self.portrait(path: movie.posterPath, provider: movie.streamIcon))
        case let .episode(id):
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first, let series = episode.series else { return nil }
            return PlaybackSource(request: .init(kind: .series, id: series.id, categoryID: series.categoryId),
                                  url: Self.portrait(path: series.posterPath, provider: series.cover))
        case .live: return nil
        }
    }

    private nonisolated static func portrait(path: String?, provider: String?) -> URL? {
        if let stored = TMDBArtworkURL.poster(path) { return stored }
        return PosterArtworkSource(provider: provider, posterPath: nil).providerURL
    }

    private struct Snapshot {
        let tmdbID: Int?
        let path: String?
        let checkedAt: Date?
    }

    func lookup(_ request: PosterArtworkRequest, profile: UUID?, restriction: ContentRestriction) async throws -> PosterLookupResult {
        try Task.checkCancellation()
        guard profile == ActiveProfileStore.current, !restriction.hides(categoryID: request.categoryID),
              let stored = snapshot(request) else { throw CancellationError() }
        if PosterArtworkSource(provider: nil, posterPath: stored.path).tmdbURL != nil {
            Logger.network.info("Poster artwork recovered from catalog")
            return PosterLookupResult(path: stored.path, checkedAt: stored.checkedAt ?? .now)
        }
        if TMDBFreshness.isFresh(stored.checkedAt), let checkedAt = stored.checkedAt {
            return PosterLookupResult(path: nil, checkedAt: checkedAt)
        }
        guard let tmdbID = stored.tmdbID else {
            Logger.network.notice("Poster metadata unavailable: no TMDB ID")
            throw TMDBError.missingToken
        }
        guard TMDBClient.shared.isConfigured else {
            Logger.network.notice("Poster metadata unavailable: TMDB not configured")
            throw TMDBError.missingToken
        }
        let path: String?
        do {
            path = try await TMDBClient.shared.posterPath(tmdbID, isMovie: request.kind == .movie)
        } catch TMDBError.serverError(404) {
            // A successful absence is durable; transport/server errors are not.
            path = nil
        } catch {
            if !Task.isCancelled {
                let code = (error as NSError).code
                Logger.network.notice("Poster metadata lookup failed (code \(code, privacy: .public)); retry deferred")
            }
            throw error
        }
        try Task.checkCancellation()
        guard profile == ActiveProfileStore.current else { throw CancellationError() }
        let result = PosterLookupResult(path: path, checkedAt: .now)
        // Return the value immediately. Persistence has its own off-main actor
        // lifetime, so the card does not wait for SQLite or a context merge.
        Task { persist(result, request: request, tmdbID: tmdbID, profile: profile) }
        Logger.network.info("Poster metadata recovered: \(path == nil ? "no poster" : "poster found", privacy: .public)")
        return result
    }

    private func snapshot(_ request: PosterArtworkRequest) -> Snapshot? {
        let context = ModelContext(container)
        let id = request.id
        switch request.kind {
        case .movie:
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let item = try? context.fetch(descriptor).first else { return nil }
            return Snapshot(tmdbID: item.tmdbId, path: item.posterPath, checkedAt: item.posterCheckedAt)
        case .series:
            var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let item = try? context.fetch(descriptor).first else { return nil }
            return Snapshot(tmdbID: item.tmdbId, path: item.posterPath, checkedAt: item.posterCheckedAt)
        }
    }

    private func persist(_ result: PosterLookupResult, request: PosterArtworkRequest, tmdbID: Int, profile: UUID?) {
        guard profile == ActiveProfileStore.current else { return }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = request.id
        switch request.kind {
        case .movie:
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let item = try? context.fetch(descriptor).first, item.tmdbId == tmdbID,
                  (item.posterCheckedAt ?? .distantPast) <= result.checkedAt else { return }
            item.posterPath = result.path ?? item.posterPath
            item.posterCheckedAt = result.checkedAt
        case .series:
            var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let item = try? context.fetch(descriptor).first, item.tmdbId == tmdbID,
                  (item.posterCheckedAt ?? .distantPast) <= result.checkedAt else { return }
            item.posterPath = result.path ?? item.posterPath
            item.posterCheckedAt = result.checkedAt
        }
        do {
            try context.save()
        } catch {
            Logger.database.error("Poster metadata save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

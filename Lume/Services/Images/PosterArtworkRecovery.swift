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
        guard let tmdbID = stored.tmdbID, TMDBClient.shared.isConfigured else { throw TMDBError.missingToken }
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

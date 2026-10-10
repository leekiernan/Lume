import Foundation

/// One routing policy for details, artwork and the chunk indexer. Negotiation
/// and payload delivery precede the device-token guard. No ratings suppression
/// is implied by a complete TMDB group.
nonisolated struct LumeTitleMetadataRouter {
    let tmdb: TMDBClient
    let proxy: LumeMetadataClient

    init(tmdb: TMDBClient = .shared, proxy: LumeMetadataClient = .shared) {
        self.tmdb = tmdb
        self.proxy = proxy
    }

    func details(id: Int, type: LumeMetadataKind, source: LumeProxySource?) async throws -> TMDBTitleDetails? {
        try Task.checkCancellation()
        if let source {
            let result = try await proxy.fetch(source: source, type: type, ids: [id], language: tmdb.language)
            if case let .available(items, _) = result {
                if let details = items[id] { return details }
            }
        }
        // Foreground enrichment keeps main's device path for every proxy
        // miss/status. Only the background indexer briefly defers pending work.
        return try await deviceDetails(id: id, type: type)
    }

    func deviceDetails(id: Int, type: LumeMetadataKind) async throws -> TMDBTitleDetails? {
        try Task.checkCancellation()
        guard id > 0, tmdb.isConfigured else { return nil }
        switch type {
        case .movie: return try await tmdb.movieDetails(id)
        case .series: return try await tmdb.tvDetails(id)
        }
    }
}

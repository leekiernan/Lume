import Foundation

/// One routing policy for details, artwork, ratings and the chunk indexer.
/// Negotiation and payload delivery precede the device-token guard. A complete
/// TMDB group never implies ratings; only an advertised, fresh ratings stamp
/// skips the device's MDBList call.
nonisolated struct LumeTitleMetadataRouter {
    let tmdb: TMDBClient
    let proxy: LumeMetadataClient
    let mdbList: MDBListClient

    init(tmdb: TMDBClient = .shared, proxy: LumeMetadataClient = .shared, mdbList: MDBListClient = .shared) {
        self.tmdb = tmdb
        self.proxy = proxy
        self.mdbList = mdbList
    }

    /// Whether a ratings lookup can produce anything for a title from `source`.
    func canFetchRatings(source: LumeProxySource?) -> Bool {
        source != nil || mdbList.isConfigured
    }

    /// The proxy's ratings when fresh for the title's age, else the device's
    /// own MDBList call. The proxy read shares the detail read's URL, so right
    /// after detail enrichment it is answered from the client's response cache.
    /// Nil when neither has ratings: callers keep what they have, unstamped.
    func ratings(id: Int, type: LumeMetadataKind, releaseDate: String?, source: LumeProxySource?,
                 now: Date = Date()) async throws -> LumeTitleRatings?
    {
        try Task.checkCancellation()
        guard id > 0 else { return nil }
        var proxied: LumeTitleRatings?
        if let source, case let .available(items, _) = try await proxy.fetch(source: source, type: type, ids: [id], language: tmdb.language) {
            proxied = items[id]?.proxyRatings
            if let proxied, RatingsFreshness.isFresh(proxied.fetchedAt, releaseDate: releaseDate, now: now) { return proxied }
        }
        guard mdbList.isConfigured else { return proxied }
        let ratings = try await mdbList.ratings(tmdbId: id, type: type == .movie ? .movie : .show)
        return LumeTitleRatings(ratings: ratings, fetchedAt: Date())
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

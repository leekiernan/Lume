import Foundation

/// Favourites change list status only. History removal is deliberately not used.
nonisolated extension SimklClient {
    func setWatchlist(_ target: TrackerMutation.Target, watchlisted: Bool, accessToken: String) async throws -> Bool {
        guard let items = SimklWatchlistMutation(target: target, watchlisted: watchlisted) else { return false }
        if !watchlisted {
            // A stale local list must not move a currently watching/completed title
            // to Dropped. Failed reads throw, leaving the durable intent queued.
            _ = try await activities(accessToken: accessToken)
            let bucket: SimklWatchlistBucket = switch target {
            case .movie: .movies
            case .show: .shows
            case .episode: .shows
            }
            let entries = try await planToWatch(bucket, accessToken: accessToken)
                + planToWatch(.anime, accessToken: accessToken)
            guard entries.contains(where: { $0.target == target }) else { return true }
        }
        let response: SimklWatchlistMutationResponse = try await post("/sync/add-to-list", body: items, accessToken: accessToken)
        guard response.accepted(status: watchlisted ? "plantowatch" : "dropped") else { throw SimklError.itemNotFound }
        return true
    }
}

nonisolated struct SimklWatchlistMutation: Encodable {
    let movies: [SimklWatchlistMutationItem]?
    let shows: [SimklWatchlistMutationItem]?

    init?(target: TrackerMutation.Target, watchlisted: Bool) {
        let status = watchlisted ? "plantowatch" : "dropped"
        switch target {
        case let .movie(tmdbID):
            movies = [SimklWatchlistMutationItem(ids: SimklIDs(tmdb: tmdbID), status: status)]
            shows = nil
        case let .show(tmdbID):
            movies = nil
            shows = [SimklWatchlistMutationItem(ids: SimklIDs(tmdb: tmdbID), status: status)]
        case .episode:
            return nil
        }
    }
}

nonisolated struct SimklWatchlistMutationItem: Encodable {
    let ids: SimklIDs
    let status: String
    enum CodingKeys: String, CodingKey { case ids; case status = "to" }
}

private nonisolated struct SimklWatchlistMutationResponse: Decodable {
    struct Items: Decodable {
        let movies: [SimklWatchlistMutationResult]?
        let shows: [SimklWatchlistMutationResult]?
    }

    let added: Items

    func accepted(status: String) -> Bool {
        let items = (added.movies ?? []) + (added.shows ?? [])
        return items.count == 1 && items[0].status == status
    }
}

private nonisolated struct SimklWatchlistMutationResult: Decodable {
    let status: String
    enum CodingKeys: String, CodingKey { case status = "to" }
}

nonisolated extension SimklWatchlistEntry {
    var target: TrackerMutation.Target {
        switch kind {
        case .movie: .movie(tmdbID: tmdbID)
        case .show: .show(tmdbID: tmdbID)
        }
    }
}

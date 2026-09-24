//
//  TraktMutationDelivery.swift
//  Lume
//
//  Translates one durable mutation into the matching Trakt sync request.
//

import Foundation

extension TraktClient {
    /// Returns false only for a malformed kind/target pairing. Network and API
    /// failures still throw so the caller retains the mutation for retry.
    func apply(_ mutation: TraktMutation, accessToken: String) async throws -> Bool {
        switch mutation.kind {
        case .history:
            guard let items = historyItems(for: mutation.target) else { return false }
            if mutation.isPresent {
                try await addToHistory(items, accessToken: accessToken)
            } else {
                try await removeFromHistory(items, accessToken: accessToken)
            }
        case .watchlist:
            guard let items = watchlistItems(for: mutation.target) else { return false }
            if mutation.isPresent {
                try await addToWatchlist(items, accessToken: accessToken)
            } else {
                try await removeFromWatchlist(items, accessToken: accessToken)
            }
        }
        return true
    }

    private func historyItems(for target: TraktMutation.Target) -> TraktSyncItems? {
        switch target {
        case let .movie(tmdbID):
            TraktSyncItems.movie(tmdbID: tmdbID)
        case let .episode(showTMDBID, season, episode):
            TraktSyncItems.episode(
                showTMDBID: showTMDBID,
                season: season,
                episode: episode
            )
        case .show:
            nil
        }
    }

    private func watchlistItems(for target: TraktMutation.Target) -> TraktWatchlistSyncItems? {
        switch target {
        case let .movie(tmdbID):
            TraktWatchlistSyncItems.movie(tmdbID: tmdbID)
        case let .show(tmdbID):
            TraktWatchlistSyncItems.show(tmdbID: tmdbID)
        case .episode:
            nil
        }
    }
}

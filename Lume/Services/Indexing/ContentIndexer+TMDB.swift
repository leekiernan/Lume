//
//  ContentIndexer+TMDB.swift
//  Lume
//
//  The indexer's TMDB lookups: title searches that retry without the
//  provider's (often wrong) year, and the split between permanent failures,
//  which skip an item, and transient ones, which end the run.
//

import Foundation

extension ContentIndexer {
    /// Provider year tags are often wrong, so a year-constrained search that
    /// finds nothing is retried without the year.
    func searchMovieID(query: String, year: Int?) async throws -> Int? {
        if let id = try await tmdbClient.searchMovieID(query: query, year: year) {
            return id
        }
        guard year != nil else { return nil }
        return try await tmdbClient.searchMovieID(query: query, year: nil)
    }

    func searchTVID(query: String, year: Int?) async throws -> Int? {
        if let id = try await tmdbClient.searchTVID(query: query, year: year) {
            return id
        }
        guard year != nil else { return nil }
        return try await tmdbClient.searchTVID(query: query, year: nil)
    }

    /// Runs a TMDB request, converting *permanent* failures (no match, bad
    /// payload) into nil so the item proceeds without TMDB data. Transient
    /// failures (offline, 5xx, rate limit) rethrow and end the run — the next
    /// kick retries those items.
    func skippingPermanentFailures<T>(_ request: () async throws -> T?) async throws -> T? {
        do {
            return try await request()
        } catch let error as TMDBError {
            switch error {
            case let .serverError(code) where code == 404:
                return nil
            case .decodingError, .invalidURL, .missingToken:
                return nil
            case .serverError, .invalidResponse:
                throw error
            }
        }
    }
}

//
//  TMDBListProvider.swift
//  Lume
//
//  Builds a custom row from a TMDB page — either someone's own list
//  (<https://www.themoviedb.org/list/12345>) or one of the curated feeds the
//  site publishes, like <https://www.themoviedb.org/movie/top-rated>.
//
//  Like `MDBListProvider`, the user pastes the page they were looking at and
//  the provider works out the API call behind it. Unlike MDBList this needs the
//  app's TMDB credentials, so it reports itself unavailable when they're
//  missing rather than failing every fetch with an auth error.
//

import Foundation

nonisolated struct TMDBListProvider: HomeListProvider {
    static let id = "tmdb"

    private static let hosts: Set<String> = ["themoviedb.org", "www.themoviedb.org"]

    /// The curated feeds, keyed by the website path that shows them. TMDB's own
    /// URLs hyphenate where the API underscores.
    private static let curatedFeeds: [String: (path: String, media: HomeListEntry.MediaType)] = [
        "movie": ("movie/popular", .movie),
        "movie/popular": ("movie/popular", .movie),
        "movie/top-rated": ("movie/top_rated", .movie),
        "movie/upcoming": ("movie/upcoming", .movie),
        "movie/now-playing": ("movie/now_playing", .movie),
        "tv": ("tv/popular", .series),
        "tv/popular": ("tv/popular", .series),
        "tv/top-rated": ("tv/top_rated", .series),
        "tv/on-the-air": ("tv/on_the_air", .series),
        "tv/airing-today": ("tv/airing_today", .series)
    ]

    private let client: TMDBClient

    init(client: TMDBClient = .shared) {
        self.client = client
    }

    var displayName: String {
        "TMDB"
    }

    var exampleURL: String {
        "https://www.themoviedb.org/movie/top-rated"
    }

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return Self.hosts.contains(host)
    }

    func entries(for url: URL) async throws -> [HomeListEntry] {
        guard client.isConfigured else { throw HomeListError.unsupportedSource }
        guard let feed = Self.feed(for: url) else { throw HomeListError.invalidURL }

        let entries: [TMDBListEntry]
        do {
            entries = try await client.listEntries(apiPath: feed.path, media: feed.media)
        } catch let error as TMDBError {
            throw Self.listError(from: error)
        } catch {
            throw HomeListError.network(error.localizedDescription)
        }

        let mapped = entries.map {
            HomeListEntry(tmdbId: $0.id, mediaType: $0.mediaType, title: $0.title)
        }
        guard !mapped.isEmpty else { throw HomeListError.emptyList }
        return mapped
    }

    func suggestedTitle(for url: URL) -> String? {
        guard let feed = Self.feed(for: url) else { return nil }
        // "movie/top_rated" → "Top Rated"; a user list has no name in its URL,
        // so it falls back to the generic one.
        guard let slug = feed.path.split(separator: "/").last, feed.path.hasPrefix("movie/") || feed.path.hasPrefix("tv/") else {
            return String(localized: "TMDB List")
        }
        let words = slug.split(whereSeparator: { $0 == "_" || $0 == "-" })
        guard !words.isEmpty else { return nil }
        return words.map(\.capitalized).joined(separator: " ")
    }

    // MARK: - URL shaping

    /// Resolves a themoviedb.org URL to the API path behind it, and the media
    /// kind its rows are (nil for a user list, whose rows say for themselves).
    static func feed(for url: URL) -> (path: String, media: HomeListEntry.MediaType?)? {
        var components = url.path.split(separator: "/").map(String.init)
        // Titles carry a slug after the id — "/movie/603-the-matrix" — but those
        // are single titles, not lists, and are rejected below.
        guard !components.isEmpty else { return nil }

        if components.first?.lowercased() == "list", components.count >= 2 {
            // "/list/12345-my-list" → list id is the leading digits.
            let raw = components[1]
            let id = raw.prefix { $0.isNumber }
            guard !id.isEmpty else { return nil }
            return ("list/\(id)", nil)
        }

        // Curated feeds are at most two components; anything deeper is a title
        // page, a person, or a season.
        components = Array(components.prefix(2))
        let key = components.joined(separator: "/").lowercased()
        guard let feed = curatedFeeds[key] else { return nil }
        return (feed.path, feed.media)
    }

    /// TMDB's own errors, in the section editor's vocabulary.
    private static func listError(from error: TMDBError) -> HomeListError {
        switch error {
        case .missingToken: .unsupportedSource
        case .invalidURL: .invalidURL
        case let .serverError(code) where code == 404: .listNotFound
        case let .serverError(code): .serverError(code)
        case .invalidResponse, .decodingError: .listNotFound
        }
    }
}

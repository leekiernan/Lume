//
//  TMDBClient+Lists.swift
//  Lume
//
//  Fetching an arbitrary TMDB collection — a user's list, or one of the curated
//  feeds like "Top Rated Movies" — so a custom Home row can be built from it
//  (`TMDBListProvider`). `trending` stays as it is: it has its own cache and
//  hero-shaped result, and is on the launch path.
//
//  A user list mixes media, so each item names its own kind; a curated feed is
//  single-medium and the caller supplies the kind instead.
//

import Foundation

/// One entry of a TMDB collection, reduced to what a section needs.
nonisolated struct TMDBListEntry: Hashable {
    let id: Int
    let mediaType: HomeListEntry.MediaType
    let title: String
}

extension TMDBClient {
    /// How many pages to walk. TMDB serves 20 per page, so this is 100 titles —
    /// comfortably more than a row shows, and enough that a sparse catalog
    /// still finds matches.
    static let listPageLimit = 5

    /// Fetches `apiPath` (e.g. `list/12345`, `movie/top_rated`), following
    /// pagination up to `TMDBClient.listPageLimit`.
    ///
    /// `media` is the kind every item has, for the curated feeds that don't say;
    /// pass nil for a user list, whose items carry their own `media_type`.
    /// Entries of any other kind — a person on a mixed list — are dropped.
    func listEntries(
        apiPath: String,
        media: HomeListEntry.MediaType?,
        pages: Int = TMDBClient.listPageLimit
    ) async throws -> [TMDBListEntry] {
        let separator = apiPath.contains("?") ? "&" : "?"
        let first: TMDBListPage = try await get("/\(apiPath)\(separator)page=1")
        let pageCount = min(max(pages, 1), max(first.totalPages ?? 1, 1))

        var entries = first.entries(defaulting: media)
        guard pageCount > 1 else { return entries }

        // Sequential rather than concurrent: this runs while the user watches an
        // empty row, not on a deadline, and TMDB rate-limits per client.
        for page in 2 ... pageCount {
            let next: TMDBListPage = try await get("/\(apiPath)\(separator)page=\(page)")
            entries.append(contentsOf: next.entries(defaulting: media))
        }
        return entries
    }
}

// MARK: - DTOs

/// A page of either shape TMDB uses: curated feeds key their rows `results`,
/// a user list keys them `items`.
private nonisolated struct TMDBListPage: Decodable {
    let results: [TMDBListRow]?
    let items: [TMDBListRow]?
    let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case results, items
        case totalPages = "total_pages"
    }

    func entries(defaulting media: HomeListEntry.MediaType?) -> [TMDBListEntry] {
        (results ?? items ?? []).compactMap { $0.entry(defaulting: media) }
    }
}

private nonisolated struct TMDBListRow: Decodable {
    let id: Int?
    let title: String?
    let name: String?
    let mediaType: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name
        case mediaType = "media_type"
    }

    func entry(defaulting media: HomeListEntry.MediaType?) -> TMDBListEntry? {
        guard let id else { return nil }
        let kind: HomeListEntry.MediaType? = switch mediaType {
        case "movie": .movie
        case "tv": .series
        case .some: nil // a person, or something we don't show
        case nil: media
        }
        guard let kind else { return nil }
        return TMDBListEntry(id: id, mediaType: kind, title: title ?? name ?? "")
    }
}

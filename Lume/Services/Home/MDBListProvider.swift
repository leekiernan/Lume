//
//  MDBListProvider.swift
//  Lume
//
//  Builds a custom Home row from an MDBList list page, e.g.
//  <https://mdblist.com/lists/official/movies/popular>. MDBList serves the
//  machine-readable form of any public list from a `/json` suffix on the same
//  path, so the user pastes the page they were looking at and we work out the
//  rest. No API key is involved — `MDBListClient` (ratings) is a separate,
//  key'd surface.
//

import Foundation

nonisolated struct MDBListProvider: HomeListProvider {
    static let id = "mdblist"

    /// MDBList list pages are `https://mdblist.com/lists/<owner>/<slug>` (the
    /// official lists nest one level deeper).
    private static let hosts: Set<String> = ["mdblist.com", "www.mdblist.com"]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var displayName: String {
        "MDBList"
    }

    var exampleURL: String {
        "https://mdblist.com/lists/official/movies/popular"
    }

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return Self.hosts.contains(host)
    }

    func entries(for url: URL) async throws -> [HomeListEntry] {
        guard let jsonURL = Self.jsonURL(for: url) else { throw HomeListError.invalidURL }

        var request = URLRequest(url: jsonURL)
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HomeListError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw HomeListError.network("") }
        // MDBList answers an unknown list with 404 *and* an empty array body, so
        // the status is what distinguishes "no such list" from "list is empty".
        guard http.statusCode != 404 else { throw HomeListError.listNotFound }
        guard (200 ... 299).contains(http.statusCode) else {
            throw HomeListError.serverError(http.statusCode)
        }

        guard let items = try? JSONDecoder().decode([MDBListListItem].self, from: data) else {
            throw HomeListError.listNotFound
        }
        let entries = items.compactMap(\.homeListEntry)
        guard !entries.isEmpty else { throw HomeListError.emptyList }
        return entries
    }

    func suggestedTitle(for url: URL) -> String? {
        // ".../lists/official/movies/popular" → "Popular". The slug is the last
        // meaningful path component, with any `/json` suffix already gone.
        guard let slug = Self.listPath(for: url)?.split(separator: "/").last else { return nil }
        let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard !words.isEmpty else { return nil }
        return words.map(\.capitalized).joined(separator: " ")
    }

    // MARK: - URL shaping

    /// The JSON feed for a list page. Idempotent: a URL the user pasted
    /// *already* pointing at `/json` maps to itself rather than `/json/json`.
    /// Query and fragment are dropped — MDBList ignores them on this endpoint
    /// (the row count is fixed), and keeping them would only churn the cache key.
    static func jsonURL(for url: URL) -> URL? {
        guard let path = listPath(for: url) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = url.host?.lowercased()
        components.path = "/\(path)/json"
        return components.url
    }

    /// The `lists/<owner>/<slug>` portion of a list page URL, with any leading
    /// or trailing slash and any trailing `/json` removed. Nil when the URL
    /// isn't a list page at all (an MDBList board, search or profile URL).
    private static func listPath(for url: URL) -> String? {
        var components = url.path.split(separator: "/").map(String.init)
        if components.last?.lowercased() == "json" { components.removeLast() }
        guard components.first?.lowercased() == "lists", components.count >= 2 else { return nil }
        return components.joined(separator: "/")
    }
}

// MARK: - DTOs

/// One entry of an MDBList list feed. `id` is the TMDB id (MDBList keys its
/// lists on TMDB), and `mediatype` is `movie` or `show`. Everything else the
/// feed carries — `imdb_id`, `tvdbid`, `rank`, `release_year` — is unused: the
/// row shows the *local* catalog title, and the feed's array order is the
/// list's order.
private nonisolated struct MDBListListItem: Decodable {
    let id: Int?
    let title: String?
    let mediatype: String?

    var homeListEntry: HomeListEntry? {
        guard let id else { return nil }
        let mediaType: HomeListEntry.MediaType
        switch mediatype?.lowercased() {
        case "movie": mediaType = .movie
        case "show", "tv", "series": mediaType = .series
        default: return nil
        }
        return HomeListEntry(tmdbId: id, mediaType: mediaType, title: title ?? "")
    }
}

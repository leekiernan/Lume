//
//  HomeListProvider.swift
//  Lume
//
//  Resolves a public "list" URL the user pastes into a custom Home row
//  (`CustomHomeSection`) into TMDB-keyed entries, which Home then matches
//  against the local catalog exactly the way the trending rows do.
//
//  One provider per site. The user pastes the human-readable list page URL and
//  the provider works out the machine-readable form — they should never have to
//  know that MDBList serves JSON from a `/json` suffix. Adding a second site
//  means adding a provider here and listing it in `HomeListCatalog.providers`.
//

import Foundation

/// A single title from a remote list, keyed by TMDB id (the same key the
/// trending and Trakt rows match on) and ordered by the list's own ordering.
nonisolated struct HomeListEntry: Hashable {
    enum MediaType: Hashable {
        case movie
        case series
    }

    let tmdbId: Int
    let mediaType: MediaType
    /// The list's own title for the entry. Only used for diagnostics and the
    /// editor's preview — the row itself shows the local catalog's title.
    let title: String
}

nonisolated enum HomeListError: LocalizedError, Equatable {
    /// The URL doesn't belong to any provider we know how to read.
    case unsupportedSource
    case invalidURL
    /// The provider answered, but there is no list at that address.
    case listNotFound
    case serverError(Int)
    case emptyList
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            String(localized: "Lume doesn't recognise that site. Paste a list URL from MDBList.")
        case .invalidURL:
            String(localized: "That doesn't look like a valid link.")
        case .listNotFound:
            String(localized: "No list found at that address. Check the link and try again.")
        case let .serverError(code):
            String(localized: "The list provider returned an error (\(code)).")
        case .emptyList:
            String(localized: "That list is empty.")
        case let .network(message):
            message
        }
    }
}

/// A site Lume can build a custom Home row from.
nonisolated protocol HomeListProvider: Sendable {
    /// Stable identifier, for diagnostics.
    static var id: String { get }
    /// Shown in the editor as the source of a section ("MDBList").
    var displayName: String { get }
    /// A real list URL, shown as the editor's placeholder / hint.
    var exampleURL: String { get }

    /// Whether this provider serves `url`. Matched on host, so a provider claims
    /// its site whether or not the specific path is valid.
    func canHandle(_ url: URL) -> Bool

    /// The list at `url`, in the list's own order.
    func entries(for url: URL) async throws -> [HomeListEntry]

    /// A title to suggest when the user hasn't typed one, derived from the URL.
    func suggestedTitle(for url: URL) -> String?
}

/// The providers Lume knows about, and the entry point Home and the section
/// editor both go through.
nonisolated enum HomeListCatalog {
    static let providers: [any HomeListProvider] = [MDBListProvider(), TMDBListProvider()]

    /// The provider for a raw URL string, or nil when nothing handles it.
    static func provider(for raw: String) -> (any HomeListProvider)? {
        guard let url = normalizedInputURL(raw) else { return nil }
        return providers.first { $0.canHandle(url) }
    }

    /// Fetches the list behind `raw`, throwing a `HomeListError` the editor can
    /// show verbatim.
    static func entries(for raw: String) async throws -> [HomeListEntry] {
        guard let url = normalizedInputURL(raw) else { throw HomeListError.invalidURL }
        guard let provider = providers.first(where: { $0.canHandle(url) }) else {
            throw HomeListError.unsupportedSource
        }
        return try await provider.entries(for: url)
    }

    static func suggestedTitle(for raw: String) -> String? {
        guard let url = normalizedInputURL(raw) else { return nil }
        return providers.first { $0.canHandle(url) }?.suggestedTitle(for: url)
    }

    /// Turns what the user typed into a URL: trims whitespace and assumes
    /// `https` when they pasted a bare `mdblist.com/…`, which is what a copy
    /// from a browser's address bar often gives.
    static func normalizedInputURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }
}

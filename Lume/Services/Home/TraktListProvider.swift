//
//  TraktListProvider.swift
//  Lume
//
//  Builds a custom row from a public Trakt list, e.g.
//  <https://trakt.tv/users/alice/lists/classic-rewatch> or the same page on
//  the new web app, `app.trakt.tv/users/alice/lists/classic-rewatch?mode=media`.
//
//  Like the other providers, the user pastes the page they were looking at and
//  the provider works out the API call behind it. Public lists need only the
//  app's Trakt API key, so this works whether or not the viewer has connected
//  a Trakt account — and reports itself unavailable when the key is missing.
//  When an account is connected its token rides along, so the viewer's own
//  private lists work too.
//

import Foundation

nonisolated struct TraktListProvider: HomeListProvider {
    static let id = "trakt"

    /// The classic site, the new web app, and the API itself.
    private static let hosts: Set<String> = ["trakt.tv", "www.trakt.tv", "app.trakt.tv", "api.trakt.tv"]

    private let client: TraktClient
    /// The connected account's token, or nil when there isn't one. Injected so
    /// tests don't reach the real `TraktService` and its Keychain.
    private let accessToken: @Sendable () async -> String?

    init(
        client: TraktClient = .shared,
        accessToken: @escaping @Sendable () async -> String? = { await TraktService.shared.listAccessToken() }
    ) {
        self.client = client
        self.accessToken = accessToken
    }

    var displayName: String {
        "Trakt"
    }

    var exampleURL: String {
        "https://trakt.tv/users/garycrawfordgc/lists/latest-releases"
    }

    func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return Self.hosts.contains(host)
    }

    func entries(for url: URL) async throws -> [HomeListEntry] {
        guard client.isConfigured else { throw HomeListError.unsupportedSource }
        guard let list = Self.list(for: url) else { throw HomeListError.invalidURL }

        let token = await accessToken()
        let entries: [TraktListEntry]
        do {
            entries = try await client.listEntries(apiPath: list.itemsPath, accessToken: token)
        } catch let error as TraktError {
            throw Self.listError(from: error, signedIn: token != nil)
        } catch {
            throw HomeListError.network(error.localizedDescription)
        }

        let mapped = entries.map {
            HomeListEntry(tmdbId: $0.tmdbId, mediaType: $0.mediaType, title: $0.title)
        }
        guard !mapped.isEmpty else { throw HomeListError.emptyList }
        return mapped
    }

    func suggestedTitle(for url: URL) -> String? {
        guard let list = Self.list(for: url) else { return nil }
        // "classic-rewatch" → "Classic Rewatch". A list addressed by its numeric
        // Trakt id has no name in its URL, so it falls back to the generic one.
        guard !list.id.allSatisfy(\.isNumber) else { return String(localized: "Trakt List") }
        let words = list.id.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard !words.isEmpty else { return nil }
        return words.map(\.capitalized).joined(separator: " ")
    }

    // MARK: - URL shaping

    /// A list as Trakt's API addresses it: by owner and slug, or — for lists
    /// shared by link, `trakt.tv/lists/<id>` — by id alone.
    struct ListReference: Equatable {
        var owner: String?
        var id: String

        /// The API path of the list's items, each component percent-encoded
        /// (usernames may contain characters a path can't carry raw).
        var itemsPath: String {
            let parts = (owner.map { ["users", $0] } ?? []) + ["lists", id, "items"]
            return parts
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? $0 }
                .joined(separator: "/")
        }
    }

    /// Resolves a Trakt list URL to the list behind it. Query and fragment are
    /// dropped — `mode=media`, `sort=…` are the web page's display settings —
    /// and so is anything after the list id, like an API URL's `/items` or a
    /// type filter. Nil when the URL isn't a list page (a title, a profile, a
    /// user's list index).
    static func list(for url: URL) -> ListReference? {
        let components = url.path.split(separator: "/").map { String($0) }
        let lowered = components.map { $0.lowercased() }

        if lowered.count >= 4, lowered[0] == "users", lowered[2] == "lists" {
            return ListReference(owner: components[1], id: components[3])
        }
        if lowered.count >= 2, lowered[0] == "lists" {
            return ListReference(owner: nil, id: components[1])
        }
        return nil
    }

    /// Trakt's errors, in the section editor's vocabulary. Trakt answers 403
    /// both for a private list and for one that doesn't exist, so the two share
    /// a message that covers either — worded for whether the request carried
    /// the viewer's account, since signed in their own lists would have opened.
    static func listError(from error: TraktError, signedIn: Bool) -> HomeListError {
        switch error {
        case .notConfigured: .unsupportedSource
        case .notAuthenticated, .server(403): signedIn ? .listNotShared : .privateList
        case .server(404), .decoding, .invalidResponse: .listNotFound
        case let .server(code): .serverError(code)
        case .authorizationPending, .slowDown, .codeExpired, .codeDenied, .codeUsed: .listNotFound
        }
    }
}

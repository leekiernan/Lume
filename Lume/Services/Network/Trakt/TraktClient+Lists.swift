//
//  TraktClient+Lists.swift
//  Lume
//
//  Reading a Trakt list's items so a custom row can be built from it
//  (`TraktListProvider`). A public list needs only the app's API key; the
//  connected user's token is sent too when there is one, which is what lets
//  their own private lists through.
//
//  Trakt lists mix media and can hold seasons, episodes and people too; each
//  item names its own kind. Seasons and episodes stand in for their show, which
//  is what a row can actually open.
//

import Foundation

/// One entry of a Trakt list, reduced to what a section needs.
nonisolated struct TraktListEntry: Hashable {
    let tmdbId: Int
    let mediaType: HomeListEntry.MediaType
    let title: String
}

nonisolated extension TraktClient {
    /// How many pages of `TraktClient.pageSize` to walk: 1,000 titles. More than
    /// a sparse catalog needs to fill a row and its "Show All" grid, without a
    /// huge list stalling the row behind a long run of sequential requests.
    static let listPageLimit = 4

    /// The items at `apiPath` (e.g. `users/alice/lists/favs/items`), in the
    /// order the list's owner chose to sort it — Trakt applies that server-side,
    /// so a "newest first" list arrives newest first. Items with no TMDB id, and
    /// people, are dropped. `accessToken` is optional: nil reads public lists
    /// only.
    func listEntries(
        apiPath: String,
        accessToken: String? = nil,
        pages: Int = TraktClient.listPageLimit
    ) async throws -> [TraktListEntry] {
        let items: [TraktListItem] = try await allPages(
            "/\(apiPath)",
            maxPages: max(pages, 1),
            accessToken: accessToken
        )
        return items.compactMap(\.entry)
    }
}

// MARK: - DTOs

/// One row of `/users/:id/lists/:list/items` or `/lists/:id/items`. `type` is
/// `movie`, `show`, `season`, `episode` or `person`; the matching child carries
/// the ids, and a season or episode also carries its `show`.
private nonisolated struct TraktListItem: Decodable {
    let type: String?
    let movie: TraktListMedia?
    let show: TraktListMedia?

    var entry: TraktListEntry? {
        let media: TraktListMedia?
        let mediaType: HomeListEntry.MediaType
        switch type?.lowercased() {
        case "movie":
            media = movie
            mediaType = .movie
        case "show", "season", "episode":
            media = show
            mediaType = .series
        default:
            return nil
        }
        guard let media, let tmdbId = media.ids?.tmdb else { return nil }
        return TraktListEntry(tmdbId: tmdbId, mediaType: mediaType, title: media.title ?? "")
    }
}

private nonisolated struct TraktListMedia: Decodable {
    let title: String?
    let ids: TraktListIDs?
}

private nonisolated struct TraktListIDs: Decodable {
    let tmdb: Int?
}

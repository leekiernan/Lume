//
//  SimklWatchedItems.swift
//  Lume
//
//  The decoded `/sync/all-items/` payload the watched-history import reads
//  (see `SimklWatchedImporter`). Split out of SimklClient.swift to keep it
//  within the size limit.
//

import Foundation

/// Decoded `/sync/all-items/` payload. Empty lists arrive as `null`, so every
/// array is optional.
nonisolated struct SimklAllItems: Decodable {
    var movies: [SimklWatchedMovie]
    var shows: [SimklWatchedShow]

    static let empty = SimklAllItems(movies: [], shows: [])

    init(movies: [SimklWatchedMovie], shows: [SimklWatchedShow]) {
        self.movies = movies
        self.shows = shows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movies = try container.decodeIfPresent([SimklWatchedMovie].self, forKey: .movies) ?? []
        let shows = try container.decodeIfPresent([SimklWatchedShow].self, forKey: .shows) ?? []
        let anime = try container.decodeIfPresent([SimklWatchedShow].self, forKey: .anime) ?? []
        self.shows = shows + anime
    }

    enum CodingKeys: String, CodingKey {
        case movies, shows, anime
    }
}

/// One entry from the movies array. Only completed movies count as watched —
/// movies have no "watching" state — but a stray `last_watched_at` is taken as
/// watched regardless of the status it carries.
nonisolated struct SimklWatchedMovie: Decodable {
    let status: String?
    let lastWatchedAt: String?
    let movie: SimklWatchedMedia

    var isWatched: Bool {
        status == "completed" || lastWatchedAt != nil
    }

    enum CodingKeys: String, CodingKey {
        case status
        case lastWatchedAt = "last_watched_at"
        case movie
    }
}

/// One entry from the shows (or anime) array, with the watched seasons and
/// episodes nested beneath it by `extended=full`.
nonisolated struct SimklWatchedShow: Decodable {
    let show: SimklWatchedMedia
    let seasons: [SimklWatchedSeason]

    init(show: SimklWatchedMedia, seasons: [SimklWatchedSeason]) {
        self.show = show
        self.seasons = seasons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        show = try container.decode(SimklWatchedMedia.self, forKey: .show)
        // A missing key means "no episode progress", not a broken response —
        // failing here would abort the whole import.
        seasons = try container.decodeIfPresent([SimklWatchedSeason].self, forKey: .seasons) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case show, seasons
    }
}

nonisolated struct SimklWatchedSeason: Decodable {
    let number: Int
    let episodes: [SimklWatchedEpisode]

    init(number: Int, episodes: [SimklWatchedEpisode]) {
        self.number = number
        self.episodes = episodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        episodes = try container.decodeIfPresent([SimklWatchedEpisode].self, forKey: .episodes) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case number, episodes
    }
}

nonisolated struct SimklWatchedEpisode: Decodable {
    let number: Int
    let lastWatchedAt: String?

    init(number: Int, lastWatchedAt: String?) {
        self.number = number
        self.lastWatchedAt = lastWatchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        // `episode_watched_at=yes` names the timestamp `watched_at`; tolerate
        // the `last_watched_at` spelling too, and a missing key entirely.
        lastWatchedAt = try container.decodeIfPresent(String.self, forKey: .watchedAt)
            ?? container.decodeIfPresent(String.self, forKey: .lastWatchedAt)
    }

    enum CodingKeys: String, CodingKey {
        case number
        case watchedAt = "watched_at"
        case lastWatchedAt = "last_watched_at"
    }
}

/// The id bag shared by watched movies and shows. Simkl mixes integers and
/// strings in its id fields, so the TMDB id decodes either way.
nonisolated struct SimklWatchedMedia: Decodable {
    let ids: SimklWatchedIDs
}

nonisolated struct SimklWatchedIDs: Decodable {
    let tmdb: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let int = try? container.decode(Int.self, forKey: .tmdb) {
            tmdb = int
        } else if let string = try? container.decode(String.self, forKey: .tmdb) {
            tmdb = Int(string)
        } else {
            tmdb = nil
        }
    }

    init(tmdb: Int?) {
        self.tmdb = tmdb
    }

    enum CodingKeys: String, CodingKey {
        case tmdb
    }
}

//
//  TraktScrobble.swift
//  Lume
//
//  Payloads shared by Trakt's start, pause and stop scrobble endpoints.
//

import Foundation

nonisolated enum TraktScrobbleAction: String, Equatable {
    case start
    case pause
    case stop
}

/// The stable catalog identity Trakt needs for a playback session. Episodes are
/// identified by their show's TMDB id plus season and episode numbers because
/// provider catalogs do not reliably carry a TMDB id for the episode itself.
nonisolated enum TraktScrobbleTarget: Equatable {
    case movie(tmdbID: Int)
    case episode(showTMDBID: Int, season: Int, episode: Int)
}

nonisolated struct TraktScrobbleEpisodePayload: Encodable {
    let season: Int
    let number: Int
}

/// Trakt accepts either a movie, or a show + episode pair, alongside a progress
/// percentage. Custom encoding omits the unused branch rather than emitting
/// null values.
nonisolated struct TraktScrobbleRequest: Encodable {
    let target: TraktScrobbleTarget
    let progress: Double

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(progress, forKey: .progress)

        switch target {
        case let .movie(tmdbID):
            try container.encode(
                TraktMoviePayload(ids: TraktIDs(tmdb: tmdbID)),
                forKey: .movie
            )
        case let .episode(showTMDBID, season, episode):
            try container.encode(
                TraktWatchlistShowPayload(ids: TraktIDs(tmdb: showTMDBID)),
                forKey: .show
            )
            try container.encode(
                TraktScrobbleEpisodePayload(season: season, number: episode),
                forKey: .episode
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case progress, movie, show, episode
    }
}

nonisolated struct TraktScrobbleResponse: Decodable {}

//
//  TraktPlayback.swift
//  Lume
//
//  The account's paused playback — movies and episodes stopped part-way, in
//  any app that scrobbles to Trakt — applied to the local catalog so Continue
//  Watching reflects it. The watched import (`TraktWatchedImporter`) only
//  brings finished plays; this is the in-progress half.
//
//  Never overwrites newer local state: an item applies only when Trakt paused
//  it after this device last watched the title. A movie already finished here
//  stays finished (Recently Watched), and an episode needs its series'
//  episodes fetched to take its position — the series itself still moves up
//  the rail by date.
//

import Foundation
import SwiftData

/// One paused item from `GET /sync/playback`.
struct TraktPlaybackItem: Decodable {
    /// Percent watched, 0...100.
    let progress: Double
    let pausedAt: String?
    let movie: TraktWatchedMedia?
    let show: TraktWatchedMedia?
    let episode: Episode?

    struct Episode: Decodable {
        let season: Int
        let number: Int
    }

    enum CodingKeys: String, CodingKey {
        case progress, movie, show, episode
        case pausedAt = "paused_at"
    }
}

extension TraktClient {
    /// The account's paused movies and episodes, newest first.
    func playback(accessToken: String) async throws -> [TraktPlaybackItem] {
        try await allPages("/sync/playback", accessToken: accessToken)
    }
}

enum TraktPlaybackImporter {
    /// Applies paused positions and dates; returns how many titles changed.
    static func apply(_ items: [TraktPlaybackItem], in context: ModelContext) -> Int {
        var movies: [Int: TraktPlaybackItem] = [:]
        var episodes: [Int: [TraktPlaybackItem]] = [:]
        for item in items {
            if let tmdb = item.movie?.ids.tmdb {
                movies[tmdb] = newer(movies[tmdb], item)
            } else if let tmdb = item.show?.ids.tmdb, item.episode != nil {
                episodes[tmdb, default: []].append(item)
            }
        }
        var changed = 0
        for movie in TrackerCatalogLookup.movies(tmdbIDs: Set(movies.keys), in: context) {
            guard let tmdb = movie.tmdbId, let item = movies[tmdb] else { continue }
            if applyMovie(item, to: movie) { changed += 1 }
        }
        for series in TrackerCatalogLookup.series(tmdbIDs: Set(episodes.keys), in: context) {
            guard let tmdb = series.tmdbId, let items = episodes[tmdb] else { continue }
            if applyEpisodes(items, to: series) { changed += 1 }
        }
        return changed
    }

    private static func applyMovie(_ item: TraktPlaybackItem, to movie: Movie) -> Bool {
        guard !movie.isWatched,
              let paused = TraktWatchedImporter.parse(item.pausedAt),
              paused > (movie.lastWatchedDate ?? .distantPast)
        else { return false }
        movie.lastWatchedDate = paused
        if let duration = movie.durationSecs, duration > 0 {
            movie.watchProgress = position(item.progress, of: duration)
        }
        return true
    }

    private static func applyEpisodes(_ items: [TraktPlaybackItem], to series: Series) -> Bool {
        var changed = false
        for item in items {
            guard let target = item.episode,
                  let paused = TraktWatchedImporter.parse(item.pausedAt)
            else { continue }
            if paused > (series.lastWatchedDate ?? .distantPast) {
                series.lastWatchedDate = paused
                changed = true
            }
            guard let episode = series.episodes.first(where: {
                $0.seasonNum == target.season && $0.episodeNum == target.number
            }), !episode.isWatched, paused > (episode.lastWatchedDate ?? .distantPast)
            else { continue }
            episode.lastWatchedDate = paused
            if let duration = episode.durationSecs, duration > 0 {
                episode.watchProgress = position(item.progress, of: duration)
            }
            changed = true
        }
        return changed
    }

    /// Seconds into a title from Trakt's percent.
    static func position(_ percent: Double, of duration: Int) -> Double {
        (min(max(percent, 0), 100) / 100 * Double(duration)).rounded()
    }

    private static func newer(_ lhs: TraktPlaybackItem?, _ rhs: TraktPlaybackItem) -> TraktPlaybackItem {
        guard let lhs else { return rhs }
        let left = TraktWatchedImporter.parse(lhs.pausedAt) ?? .distantPast
        let right = TraktWatchedImporter.parse(rhs.pausedAt) ?? .distantPast
        return right > left ? rhs : lhs
    }
}

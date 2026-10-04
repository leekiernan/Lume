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
//  stays finished (Watch Again). An episode whose row doesn't exist yet —
//  Xtream and Stalker fetch a series' episodes on first open — is parked in
//  `TraktPendingWatchedStore` and takes its position when they arrive; the
//  series itself moves up the rail by date straight away.
//

import Foundation
import SwiftData

/// One paused item from `GET /sync/playback`.
nonisolated struct TraktPlaybackItem: Decodable {
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

nonisolated enum TraktPlaybackImporter {
    /// How long a parked pause waits for its episode. Long enough for a
    /// provider a few weeks behind Trakt; short enough that a pause for an
    /// episode it never lists doesn't sit on disk forever.
    static let parkedPauseLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// Applies paused positions and dates; returns how many titles changed.
    static func apply(_ items: [TraktPlaybackItem], in context: ModelContext, now: Date = .now, pendingScope: TrackerProgressScope = .trakt) -> Int {
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
        var pending = TraktPendingWatchedStore.load(scope: pendingScope)
        let before = pending
        for series in TrackerCatalogLookup.series(tmdbIDs: Set(episodes.keys), in: context) {
            guard let tmdb = series.tmdbId, let items = episodes[tmdb] else { continue }
            let outcome = applyEpisodes(items, to: series, now: now)
            if outcome.changed { changed += 1 }
            pending[tmdb] = parking(outcome.waiting, in: pending[tmdb])
        }
        if pending != before {
            TraktPendingWatchedStore.save(pending)
        }
        return changed
    }

    /// `show` with its parked pauses replaced by `waiting` — this import's
    /// view of what is still missing — and nil once nothing is left.
    private static func parking(_ waiting: [String: TraktPendingPause], in show: TraktPendingShow?) -> TraktPendingShow? {
        let updated = TraktPendingShow(episodes: show?.episodes ?? [:], paused: waiting.isEmpty ? nil : waiting)
        return updated.isEmpty ? nil : updated
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

    /// Whether anything changed, and the pauses whose episode has no row yet.
    private static func applyEpisodes(
        _ items: [TraktPlaybackItem],
        to series: Series,
        now: Date
    ) -> (changed: Bool, waiting: [String: TraktPendingPause]) {
        var changed = false
        var waiting: [String: TraktPendingPause] = [:]
        for item in items {
            guard let target = item.episode,
                  let paused = TraktWatchedImporter.parse(item.pausedAt)
            else { continue }
            if paused > (series.lastWatchedDate ?? .distantPast) {
                series.lastWatchedDate = paused
                changed = true
            }
            switch applyPause(item.progress, pausedAt: paused, season: target.season, episode: target.number, to: series) {
            case .applied: changed = true
            case .superseded: break
            case .missing:
                waiting[TraktPendingShow.key(season: target.season, episode: target.number)] = TraktPendingPause(
                    progress: item.progress,
                    pausedAt: Int(paused.timeIntervalSince1970),
                    parkedAt: Int(now.timeIntervalSince1970)
                )
            }
        }
        return (changed, waiting)
    }

    /// Applies pauses parked for `series` now that its episodes exist, and
    /// returns the ones still waiting: their episode isn't listed yet, and
    /// they haven't outlived `parkedPauseLifetime`.
    static func applyParked(
        _ parked: [String: TraktPendingPause],
        to series: Series,
        now: Date
    ) -> [String: TraktPendingPause] {
        var waiting: [String: TraktPendingPause] = [:]
        for (key, pause) in parked {
            let parts = key.split(separator: "x")
            guard parts.count == 2, let season = Int(parts[0]), let episode = Int(parts[1]) else { continue }
            let pausedAt = Date(timeIntervalSince1970: TimeInterval(pause.pausedAt))
            let outcome = applyPause(pause.progress, pausedAt: pausedAt, season: season, episode: episode, to: series)
            let parkedAt = Date(timeIntervalSince1970: TimeInterval(pause.parkedAt))
            if outcome == .missing, now.timeIntervalSince(parkedAt) < parkedPauseLifetime {
                waiting[key] = pause
            }
        }
        return waiting
    }

    private enum PauseOutcome {
        case applied
        /// The episode exists, but is finished here or was watched more
        /// recently — nothing to do, now or later.
        case superseded
        case missing
    }

    private static func applyPause(
        _ percent: Double,
        pausedAt paused: Date,
        season: Int,
        episode number: Int,
        to series: Series
    ) -> PauseOutcome {
        guard let episode = series.episodes.first(where: { $0.seasonNum == season && $0.episodeNum == number }) else {
            return .missing
        }
        guard !episode.isWatched, paused > (episode.lastWatchedDate ?? .distantPast) else { return .superseded }
        episode.lastWatchedDate = paused
        if let duration = episode.durationSecs, duration > 0 {
            episode.watchProgress = position(percent, of: duration)
        }
        return .applied
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

//
//  ContinueWatching.swift
//  Lume
//
//  What the Continue Watching rail shows for each title: which episode a
//  series continues with, how far into it the viewer is, whether there's
//  anything left to continue, and how much of a movie remains.
//
//  A movie is finished once it's marked watched (`WatchCompletion`). A series
//  has no such flag — it's finished when its last episode is watched and
//  nothing is in progress; a new season makes it unfinished again. Pure: the
//  loader below turns a series' episodes into plain values first.
//

import Foundation
import SwiftData

/// One episode's watch state, as plain values.
nonisolated struct EpisodeMark: Equatable {
    let season: Int
    let episode: Int
    /// Seconds watched.
    let progress: Double
    let duration: Int?
    let isWatched: Bool

    fileprivate var order: (Int, Int) {
        (season, episode)
    }
}

/// Where a series continues.
nonisolated struct SeriesContinuation: Equatable {
    let season: Int
    let episode: Int
    /// How far into that episode (0...1), or nil when it has no duration.
    let fraction: Double?
}

nonisolated enum ContinueWatching {
    /// The episode a series continues with — the furthest one in progress,
    /// else the one after the furthest watched, else the first — or nil when
    /// there's nothing left: the last episode is watched and nothing is in
    /// progress. The same episode the series page's Resume/Play button picks
    /// (`SeriesEpisodeProgress`), without its wrap to the premiere.
    static func continuation(from marks: [EpisodeMark]) -> SeriesContinuation? {
        guard let first = marks.min(by: { $0.order < $1.order }) else { return nil }
        // Same thresholds as `SeriesEpisodeProgress.markers`.
        if let inProgress = marks.filter({ $0.progress > 1 && !$0.isWatched }).max(by: { $0.order < $1.order }) {
            return SeriesContinuation(
                season: inProgress.season, episode: inProgress.episode,
                fraction: fraction(progress: inProgress.progress, duration: inProgress.duration)
            )
        }
        guard let watched = marks.filter(\.isWatched).max(by: { $0.order < $1.order }) else {
            return SeriesContinuation(season: first.season, episode: first.episode, fraction: 0)
        }
        guard let next = marks.filter({ $0.order > watched.order }).min(by: { $0.order < $1.order }) else {
            return nil
        }
        return SeriesContinuation(season: next.season, episode: next.episode, fraction: 0)
    }

    /// A movie stays until it's watched to the end (`WatchCompletion`).
    static func includes(movieWatched isWatched: Bool) -> Bool {
        !isWatched
    }

    /// Seconds of a movie left, when its length is known.
    static func remaining(progress: Double, duration: Int?) -> TimeInterval? {
        guard let duration, duration > 0 else { return nil }
        return max(Double(duration) - progress, 0)
    }

    static func fraction(progress: Double, duration: Int?) -> Double? {
        guard let duration, duration > 0 else { return nil }
        return min(max(progress / Double(duration), 0), 1)
    }

    /// "32m left", "1h 5m left" (localised).
    static func remainingLabel(_ seconds: TimeInterval) -> String {
        // Whole minutes, never "0m": under a minute left still reads 1m.
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        let amount = Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return String(localized: "\(amount) left", comment: "Time remaining in a movie, e.g. \"32m left\"")
    }

    /// "S7, E12" (localised).
    static func episodeLabel(_ continuation: SeriesContinuation) -> String {
        String(
            localized: "S\(continuation.season), E\(continuation.episode)",
            comment: "Season and episode on a Continue Watching card, e.g. \"S7, E12\""
        )
    }
}

// MARK: - Loading

/// Reads where each series continues, for the few series a rail shows, off
/// the main thread. Keyed by series id; a series whose episodes this device
/// hasn't loaded yet is absent (its episodes are fetched lazily, on its page).
nonisolated enum ContinueWatchingLoader {
    struct Result: Equatable {
        var continuations: [String: SeriesContinuation] = [:]
        /// Series with nothing left to continue — out of Continue Watching,
        /// into Recently Watched. One whose episodes aren't loaded yet isn't
        /// here: it counts as in progress.
        var finished: Set<String> = []
    }

    /// Loads the split for `series`, off the main thread.
    @MainActor static func load(_ series: [Series], in context: ModelContext) async -> Result {
        let ids = series.map(\.persistentModelID)
        guard !ids.isEmpty else { return Result() }
        let container = context.container
        return await Task.detached(priority: .userInitiated) {
            load(container: container, series: ids)
        }.value
    }

    static func load(container: ModelContainer, series ids: [PersistentIdentifier]) -> Result {
        let context = ModelContext(container)
        var result = Result()
        for id in ids {
            guard let series = context.model(for: id) as? Series else { continue }
            let marks = series.episodes.map {
                EpisodeMark(
                    season: $0.seasonNum, episode: $0.episodeNum,
                    progress: $0.watchProgress, duration: $0.durationSecs, isWatched: $0.isWatched
                )
            }
            guard !marks.isEmpty else { continue }
            if let continuation = ContinueWatching.continuation(from: marks) {
                result.continuations[series.id] = continuation
            } else {
                result.finished.insert(series.id)
            }
        }
        return result
    }
}

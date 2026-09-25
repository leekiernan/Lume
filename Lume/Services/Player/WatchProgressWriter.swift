import Foundation
import SwiftData

/// Where a movie or episode counts as watched: the fraction of its duration
/// `WatchProgressWriter` marks it finished at, and the earliest point
/// `OutroTrigger` may arm the Next Episode button — one line, so advancing
/// never leaves an unfinished item behind.
nonisolated enum WatchCompletion {
    static let threshold = 0.9

    static func isComplete(progress: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && progress / duration >= threshold
    }
}

/// Persists VOD watch progress on a private background `ModelContext` so that
/// saving never runs on the main thread.
///
/// KSPlayer's render loop drops frames if a `ModelContext.save()` blocks the
/// main actor mid-playback. This actor owns its own context off the main thread
/// (the same pattern `ContentSyncManager` uses), so the player host only has to
/// hand it a few `Sendable` values; the fetch and the disk write happen here,
/// away from the render thread.
actor WatchProgressWriter {
    private let context: ModelContext

    /// Surfaced when an item crosses the "watched" line on this write, so the
    /// caller can fire a one-time Trakt sync back on the main actor.
    struct Completion {
        let ref: PlayableMedia.ContentRef
    }

    init(container: ModelContainer) {
        context = ModelContext(container)
        // We flush explicitly after each mutation; autosave would add its own
        // unscheduled saves on top.
        context.autosaveEnabled = false
    }

    /// Write `progress` for `ref` and return a `Completion` if the item just
    /// became watched (`WatchCompletion.threshold`).
    @discardableResult
    func record(
        ref: PlayableMedia.ContentRef,
        progress: TimeInterval,
        duration: TimeInterval
    ) -> Completion? {
        guard progress > 0 else { return nil }

        let completed = WatchCompletion.isComplete(progress: progress, duration: duration)

        do {
            switch ref {
            case let .movie(id):
                return try writeMovie(id: id, progress: progress, completed: completed, ref: ref)
            case let .episode(id):
                return try writeEpisode(id: id, progress: progress, completed: completed, ref: ref)
            case let .live(id):
                try touchLive(id: id)
                return nil
            }
        } catch {
            // A dropped progress write is recoverable at the next boundary;
            // never crash playback over it.
            return nil
        }
    }

    /// Mark `ref` watched outright, whatever the clock reads, returning a
    /// `Completion` if this is the write that finished it.
    ///
    /// The viewer asking for the next episode is the one case that completes an
    /// item below the 90% line `record` measures: the transport button is live
    /// from the first frame, and without this the episode left behind would keep
    /// its place in Continue Watching and never reach Trakt.
    @discardableResult
    func markWatched(ref: PlayableMedia.ContentRef, duration: TimeInterval) -> Completion? {
        do {
            switch ref {
            case let .movie(id):
                return try writeMovie(id: id, progress: duration, completed: true, ref: ref)
            case let .episode(id):
                return try writeEpisode(id: id, progress: duration, completed: true, ref: ref)
            case .live:
                return nil
            }
        } catch {
            return nil
        }
    }

    private func writeMovie(
        id: String,
        progress: TimeInterval,
        completed: Bool,
        ref: PlayableMedia.ContentRef
    ) throws -> Completion? {
        guard let movie = PlayerContentLookup.movie(id, in: context) else { return nil }

        movie.watchProgress = progress
        movie.lastWatchedDate = Date()

        var completion: Completion?
        if completed, !movie.isWatched {
            movie.isWatched = true
            completion = Completion(ref: ref)
        }

        try context.save()
        return completion
    }

    private func writeEpisode(
        id: String,
        progress: TimeInterval,
        completed: Bool,
        ref: PlayableMedia.ContentRef
    ) throws -> Completion? {
        guard let episode = PlayerContentLookup.episode(id, in: context) else { return nil }

        episode.watchProgress = progress
        episode.lastWatchedDate = Date()
        if let series = episode.series {
            series.lastWatchedDate = Date()
        }

        var completion: Completion?
        if completed, !episode.isWatched {
            episode.isWatched = true
            completion = Completion(ref: ref)
        }

        try context.save()
        return completion
    }

    private func touchLive(id: String) throws {
        guard let stream = PlayerContentLookup.liveStream(id, in: context) else { return }
        stream.lastWatchedDate = Date()
        try context.save()
    }
}

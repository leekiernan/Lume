import Foundation
import SwiftData

/// Where a movie or episode counts as watched: the fraction of its duration
/// `WatchProgressWriter` marks it finished at, and the earliest point
/// `OutroTrigger` may arm the Next Episode button. Its fallback prompt window
/// is independently capped at two minutes; completion stays at 90%.
nonisolated enum WatchCompletion {
    static let threshold = 0.9

    /// How far into a rewatch the viewer must get before the title goes back
    /// to in progress. Opening a watched episode by mistake and backing out
    /// shouldn't take its tick away.
    static let rewatchFloor: TimeInterval = 60

    /// Whether a save of `progress` short of the watched line turns a watched
    /// title back into one in progress: a rewatch under way.
    static func reopensWatched(progress: TimeInterval, completed: Bool) -> Bool {
        !completed && progress >= rewatchFloor
    }

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
    private let container: ModelContainer
    /// Made on first use, on this actor. One made in `init` belonged to the
    /// thread that built the writer — the main thread, in the player — and
    /// SwiftData warned it was "unbinding from the main queue" on the first
    /// save.
    private lazy var context: ModelContext = {
        let context = ModelContext(container)
        // We flush explicitly after each mutation; autosave would add its own
        // unscheduled saves on top.
        context.autosaveEnabled = false
        return context
    }()

    /// Channels left by a zap, and when, waiting for the next unheld write.
    /// Saving on every zap merged into the main context while the next stream
    /// opened, re-running the Live TV `@Query`s still mounted under the player
    /// inside its first-frame window; a surfing session now saves once.
    private var heldLiveTouches: [String: Date] = [:]

    /// Surfaced when a write flips an item's watched state — it crossed the
    /// watched line, or a rewatch put it back in progress — so the caller can
    /// mirror it onto the screens' model (which lags this context's save) and,
    /// for a completion, fire a one-time tracker sync, on the main actor.
    struct WatchedChange {
        let ref: PlayableMedia.ContentRef
        let isWatched: Bool
    }

    init(container: ModelContainer) {
        self.container = container
    }

    /// Write `progress` for `ref` and return a `WatchedChange` if the item just
    /// became watched (`WatchCompletion.threshold`) or a rewatch reopened it.
    @discardableResult
    func record(
        ref: PlayableMedia.ContentRef,
        progress: TimeInterval,
        duration: TimeInterval,
        holdLive: Bool = false,
        recordedAt: Date = .now
    ) -> WatchedChange? {
        guard progress > 0 else { return nil }

        let completed = WatchCompletion.isComplete(progress: progress, duration: duration)

        do {
            switch ref {
            case let .movie(id):
                guard WatchHistoryClears.shared.allows(recordedAt, for: id) else { return nil }
                return try writeMovie(id: id, progress: progress, completed: completed, ref: ref)
            case let .episode(id):
                guard WatchHistoryClears.shared.allows(recordedAt, for: id) else { return nil }
                return try writeEpisode(id: id, progress: progress, completed: completed, ref: ref)
            case let .live(id):
                if holdLive {
                    heldLiveTouches[id] = Date()
                } else {
                    try touchLive(id: id)
                }
                return nil
            }
        } catch {
            // A dropped progress write is recoverable at the next boundary;
            // never crash playback over it.
            return nil
        }
    }

    /// Mark `ref` watched outright, whatever the clock reads, returning a
    /// `WatchedChange` if this is the write that finished it.
    ///
    /// The viewer asking for the next episode is the one case that completes an
    /// item below the 90% line `record` measures: the transport button is live
    /// from the first frame, and without this the episode left behind would keep
    /// its place in Continue Watching and never reach Trakt.
    @discardableResult
    func markWatched(ref: PlayableMedia.ContentRef, duration: TimeInterval, recordedAt: Date = .now) -> WatchedChange? {
        do {
            switch ref {
            case let .movie(id):
                guard WatchHistoryClears.shared.allows(recordedAt, for: id) else { return nil }
                return try writeMovie(id: id, progress: duration, completed: true, ref: ref)
            case let .episode(id):
                guard WatchHistoryClears.shared.allows(recordedAt, for: id) else { return nil }
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
    ) throws -> WatchedChange? {
        guard let movie = PlayerContentLookup.movie(id, in: context) else { return nil }

        movie.watchProgress = progress
        movie.lastWatchedDate = Date()

        var change: WatchedChange?
        if completed, !movie.isWatched {
            movie.isWatched = true
            change = WatchedChange(ref: ref, isWatched: true)
        } else if movie.isWatched, WatchCompletion.reopensWatched(progress: progress, completed: completed) {
            // A rewatch: in progress again until it crosses the line, which
            // counts it — and scrobbles it — as a second play.
            movie.isWatched = false
            change = WatchedChange(ref: ref, isWatched: false)
        }

        try context.save()
        return change
    }

    private func writeEpisode(
        id: String,
        progress: TimeInterval,
        completed: Bool,
        ref: PlayableMedia.ContentRef
    ) throws -> WatchedChange? {
        guard let episode = PlayerContentLookup.episode(id, in: context) else { return nil }

        episode.watchProgress = progress
        episode.lastWatchedDate = Date()
        if let series = episode.series {
            series.lastWatchedDate = Date()
        }

        var change: WatchedChange?
        if completed, !episode.isWatched {
            episode.isWatched = true
            change = WatchedChange(ref: ref, isWatched: true)
        } else if episode.isWatched, WatchCompletion.reopensWatched(progress: progress, completed: completed) {
            // A rewatch: in progress again until it crosses the line.
            episode.isWatched = false
            change = WatchedChange(ref: ref, isWatched: false)
        }

        try context.save()
        return change
    }

    /// Stamps `id` and every held channel, in one save.
    private func touchLive(id: String) throws {
        var touches = heldLiveTouches
        heldLiveTouches = [:]
        touches[id] = Date()
        let ids = Array(touches.keys)
        let streams = try context.fetch(FetchDescriptor<LiveStream>(predicate: #Predicate { ids.contains($0.id) }))
        guard !streams.isEmpty else { return }
        for stream in streams {
            stream.lastWatchedDate = touches[stream.id]
        }
        try context.save()
    }
}

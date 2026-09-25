import Foundation
import SwiftData

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
    /// became watched (≥ 90%).
    @discardableResult
    func record(
        ref: PlayableMedia.ContentRef,
        progress: TimeInterval,
        duration: TimeInterval
    ) -> Completion? {
        guard progress > 0 else { return nil }

        let completed = duration > 0 && progress / duration >= 0.9

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
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let movie = try context.fetch(descriptor).first else { return nil }

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
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let episode = try context.fetch(descriptor).first else { return nil }

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
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let stream = try context.fetch(descriptor).first else { return }
        stream.lastWatchedDate = Date()
        try context.save()
    }
}

import Foundation
import SwiftData

/// Watched/reset intent, shared by card menus, details and early player exits.
/// Model mutations maintain recency/resume state; tracker queues keep their
/// existing account/profile ownership. This is a discrete action, not playback
/// clock persistence (which remains owned by `WatchProgressWriter`).
enum MediaWatchState {
    /// An early exit resets unfinished content using the same ledger and
    /// tracker delivery as a manual reset. A brief replay must not erase an
    /// existing completed watch. Returns whether this boundary was handled.
    static func discardEarlyProgress(
        ref: PlayableMedia.ContentRef, position: TimeInterval, duration: TimeInterval,
        in context: ModelContext, trackers: [any TrackerHistorySynchronizing]? = nil
    ) -> Bool {
        guard PlaybackResumePolicy.discardsProgress(position: position, duration: duration) else { return false }
        switch ref {
        case let .movie(id):
            guard let movie = PlayerContentLookup.movie(id, in: context) else { return false }
            if !movie.isWatched { setWatched(false, movie: movie, in: context, trackers: trackers) }
        case let .episode(id):
            guard let episode = PlayerContentLookup.episode(id, in: context) else { return false }
            if !episode.isWatched { setWatched(false, episode: episode, in: context, trackers: trackers) }
        case .live:
            return false
        }
        RecentResumePoints.record(0, for: ref)
        return true
    }

    static func setWatched(
        _ watched: Bool, movie: Movie, in context: ModelContext,
        trackers: [any TrackerHistorySynchronizing]? = nil
    ) {
        movie.setWatched(watched)
        try? context.save()
        for tracker in trackers ?? [TraktService.shared, SimklService.shared] {
            tracker.syncWatched(movie: movie, watched: watched)
        }
        deleteCompletedDownload(watched: watched, id: movie.id)
    }

    static func setWatched(
        _ watched: Bool, episode: Episode, in context: ModelContext,
        trackers: [any TrackerHistorySynchronizing]? = nil
    ) {
        episode.setWatched(watched)
        try? context.save()
        for tracker in trackers ?? [TraktService.shared, SimklService.shared] {
            tracker.syncWatched(episode: episode, watched: watched)
        }
        deleteCompletedDownload(watched: watched, id: episode.id)
    }

    private static func deleteCompletedDownload(watched: Bool, id: String) {
        #if !os(tvOS)
            if watched { DownloadManager.shared.checkAutoDelete(id: id) }
        #endif
    }
}

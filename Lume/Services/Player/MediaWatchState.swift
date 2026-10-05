import SwiftData

/// Manual watched intent, shared by card menus and both detail layouts.
/// Model mutations maintain recency/resume state; tracker queues keep their
/// existing account/profile ownership. This is a discrete action, not playback
/// clock persistence (which remains owned by `WatchProgressWriter`).
enum MediaWatchState {
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

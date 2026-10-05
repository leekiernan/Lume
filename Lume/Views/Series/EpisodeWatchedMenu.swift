import SwiftUI

/// Context-menu contents shared by the iOS/macOS `EpisodeCard` and the tvOS
/// `TVEpisodeCard`: finish or reset this episode, and bulk-update the
/// episodes ordered before or after it. The neighbour actions only appear when
/// such episodes actually exist.
struct EpisodeWatchedMenu: View {
    let episode: Episode
    var onSetWatched: (Bool) -> Void
    var onMarkPreviousWatched: () -> Void
    var onMarkFollowingUnwatched: () -> Void

    var body: some View {
        MediaWatchedMenu(
            state: .init(isWatched: episode.isWatched, progress: episode.watchProgress, lastWatchedDate: episode.lastWatchedDate),
            onSetWatched: onSetWatched
        )

        if episode.hasEarlierEpisodes {
            Button {
                onMarkPreviousWatched()
            } label: {
                Label("Mark All Previous as Watched", systemImage: "checkmark.circle.fill")
            }
        }

        if episode.hasLaterWatchedEpisodes {
            Button {
                onMarkFollowingUnwatched()
            } label: {
                Label("Mark All Following as Unwatched", systemImage: "arrow.counterclockwise.circle")
            }
        }
    }
}

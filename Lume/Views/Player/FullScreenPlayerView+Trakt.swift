//
//  FullScreenPlayerView+Trakt.swift
//  Lume
//
//  Transient Trakt scrobble (start/pause/stop) triggered by playback state.
//  The one-time durable "watched" sync lives in `syncWatchedServices(ref:)`
//  (FullScreenPlayerView.swift) — it now syncs Simkl alongside Trakt, so both
//  trackers share the one completion path instead of Trakt alone reaching it.
//

import Foundation
import SwiftData

extension FullScreenPlayerView {
    /// The Trakt identity and catalog duration for a playable item. This is
    /// resolved only at transport boundaries, never on the playback tick path.
    private func traktPlaybackDetails(
        for ref: PlayableMedia.ContentRef
    ) -> (target: TraktScrobbleTarget, duration: TimeInterval)? {
        switch ref {
        case let .movie(id):
            guard let movie = PlayerContentLookup.movie(id, in: modelContext),
                  let tmdbID = movie.tmdbId
            else { return nil }
            return (.movie(tmdbID: tmdbID), TimeInterval(movie.durationSecs ?? 0))
        case let .episode(id):
            guard let episode = PlayerContentLookup.episode(id, in: modelContext),
                  let showTMDBID = episode.series?.tmdbId
            else { return nil }
            return (
                .episode(
                    showTMDBID: showTMDBID,
                    season: episode.seasonNum,
                    episode: episode.episodeNum
                ),
                TimeInterval(episode.durationSecs ?? 0)
            )
        case .live:
            return nil
        }
    }

    /// Converts the shared playback clock into Trakt's percentage and emits a
    /// start/resume or pause transition. The model duration is a fallback for
    /// engines whose first playing state arrives before their duration callback.
    func updateTraktScrobble(isPlaying: Bool) {
        guard let details = traktPlaybackDetails(for: activeMedia.contentRef) else { return }
        let elapsed = clock.elapsed(fallback: activeMedia.startTime)
        let duration = clock.duration > 0 ? clock.duration : details.duration
        let progress = TraktPlaybackScrobbler.progress(elapsed: elapsed, duration: duration)

        if isPlaying {
            traktScrobbler.playbackStarted(target: details.target, progress: progress)
        } else {
            traktScrobbler.playbackPaused(target: details.target, progress: progress)
        }
    }

    /// Ends the outgoing item's Trakt session before the clock/media identity is
    /// reset by a close or in-player stream change.
    func stopTraktScrobble() {
        guard let details = traktPlaybackDetails(for: activeMedia.contentRef) else { return }
        let elapsed = clock.elapsed(fallback: activeMedia.startTime)
        let duration = clock.duration > 0 ? clock.duration : details.duration
        let progress = TraktPlaybackScrobbler.progress(elapsed: elapsed, duration: duration)
        traktScrobbler.playbackStopped(target: details.target, progress: progress)
    }
}

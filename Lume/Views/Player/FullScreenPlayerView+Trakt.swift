//
//  FullScreenPlayerView+Trakt.swift
//  Lume
//
//  Drives TraktPlaybackScrobbler from the shared playback clock: resolves the
//  active movie/episode's Trakt identity at transport boundaries (never on the
//  playback tick path) and turns clock.isPlaying transitions into the
//  scrobbler's start/pause/stop lifecycle.
//

import SwiftData
import SwiftUI

extension FullScreenPlayerView {
    /// The Trakt identity and catalog duration for a playable item. This is
    /// resolved only at transport boundaries, never on the playback tick path.
    func traktPlaybackDetails(
        for ref: PlayableMedia.ContentRef
    ) -> (target: TraktScrobbleTarget, duration: TimeInterval)? {
        switch ref {
        case let .movie(id):
            var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let movie = try? modelContext.fetch(descriptor).first,
                  let tmdbID = movie.tmdbId
            else { return nil }
            return (.movie(tmdbID: tmdbID), TimeInterval(movie.durationSecs ?? 0))
        case let .episode(id):
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let episode = try? modelContext.fetch(descriptor).first,
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
        let elapsed = max(clock.current, activeMedia.startTime)
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
        let elapsed = max(clock.current, activeMedia.startTime)
        let duration = clock.duration > 0 ? clock.duration : details.duration
        let progress = TraktPlaybackScrobbler.progress(elapsed: elapsed, duration: duration)
        traktScrobbler.playbackStopped(target: details.target, progress: progress)
    }
}

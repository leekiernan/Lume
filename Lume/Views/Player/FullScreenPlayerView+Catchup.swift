//
//  FullScreenPlayerView+Catchup.swift
//  Lume
//
//  Seeking a catch-up (timeshift) programme. Every engine hands its seeks and
//  skips on catch-up media here (`CatchupSeekRouter`) instead of byte-seeking
//  the timeshift stream, which panels only serve cleanly from the minute named
//  in the URL. A seek parks the clock on the chosen drop-in minute, waits a
//  moment for further presses, then swaps in a segment opened at that minute.
//  The decisions are `CatchupSeekPlanner`'s; this file only reads the clock
//  and swaps the stream.
//

import OSLog
import SwiftUI

extension FullScreenPlayerView {
    /// How long a seek waits for another press before its segment opens, so a
    /// run of skips opens one stream rather than one per press.
    static let catchupSeekDebounce: Duration = .milliseconds(300)

    /// A seek or skip on the catch-up programme on screen, in programme time.
    func handleCatchupSeek(_ seek: CatchupSeek) {
        guard let timeline = activeMedia.catchup,
              let offset = CatchupSeekPlanner.plan(
                  seek,
                  current: clock.current,
                  pendingTarget: pendingCatchupTarget,
                  timeline: timeline,
                  now: .now
              )
        else { return }
        pendingCatchupTarget = offset
        // Show where playback is going straight away, and keep the stream
        // still on screen from dragging the scrubber back meanwhile.
        clock.holdEngineReports(from: activeMedia.id)
        clock.current = offset
        catchupSeekTask?.cancel()
        catchupSeekTask = Task { @MainActor in
            try? await Task.sleep(for: Self.catchupSeekDebounce)
            guard !Task.isCancelled else { return }
            openCatchupSegment(at: offset, of: timeline)
        }
    }

    /// Drop a seek that hasn't opened its segment yet — the stream is changing
    /// for another reason, or the player is closing.
    func cancelPendingCatchupSeek() {
        catchupSeekTask?.cancel()
        catchupSeekTask = nil
        pendingCatchupTarget = nil
    }

    /// Swap in another segment of the programme already playing. Unlike any
    /// other swap this is a seek, not a new title:
    ///
    /// - The clock moves to the segment's offset but keeps the programme's
    ///   duration and play state (and the seek's hold on stale reports).
    /// - No Trakt stop and no progress flush: a catch-up stream is a live ref,
    ///   which never scrobbles and only stamps last-watched, which opening the
    ///   programme already did.
    /// - The engine stays put. `engineAttempt` resets on a new title so it gets
    ///   the primary engine's first try; here the viewer is mid-programme on
    ///   whichever engine proved it can play this archive. Resetting would
    ///   send every seek back through an engine that already failed on it —
    ///   one startup timeout per seek. A segment the current engine can't
    ///   open still falls back to the next engine, or ends in the error overlay.
    /// - The Now Playing session carries on; only its resume snapshot moves.
    func moveToCatchupSegment(_ segment: PlayableMedia) {
        clock.rebase(onto: segment)
        activeMedia = segment
        NowPlayingService.shared.continueSession(with: segment)
    }

    private func openCatchupSegment(at offset: TimeInterval, of timeline: CatchupTimeline) {
        pendingCatchupTarget = nil
        catchupSeekTask = nil
        // The viewer moved on to something else while the seek was pending.
        guard activeMedia.catchup?.isSameProgramme(as: timeline) == true else { return }
        // Rebuilt through `PlayableMedia.catchup`, never the URL builder
        // directly, so a segment is always the same kind of URL the programme
        // was opened with.
        guard let stream = PlayerContentLookup.liveStream(timeline.streamID, in: modelContext),
              let playlist = LiveChannelNavigator.playlist(for: stream, in: modelContext),
              let segment = PlayableMedia.catchup(
                  stream: stream,
                  playlist: playlist,
                  programTitle: timeline.programmeTitle,
                  start: timeline.programmeStart,
                  end: timeline.programmeEnd,
                  segmentStart: timeline.origin.addingTimeInterval(offset)
              )
        else {
            Logger.player.error("catch-up seek: could not rebuild the programme's archive URL")
            // The stream on screen carries on; its next report restores the clock.
            clock.releaseHold()
            return
        }
        guard segment.id != activeMedia.id else {
            // Back to the start of the segment already playing: the URL is the
            // same, so there is no swap to make — rebuild the engine on it.
            clock.releaseHold()
            clock.rebase(onto: segment)
            catchupRestartCount += 1
            return
        }
        switchMedia(to: segment)
    }
}

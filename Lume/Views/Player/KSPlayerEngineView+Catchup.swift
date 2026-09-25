//
//  KSPlayerEngineView+Catchup.swift
//  Lume
//
//  The KSPlayer host's seek funnel and its stream-swap reset. The other
//  engines route catch-up seeks inside their own coordinators; KSPlayer's
//  coordinator belongs to the library, so every KSPlayer seek — the iOS/macOS
//  overlay, the arrow keys, skip-intro, the lock screen and the tvOS overlay
//  (through `KSTVPlaybackEngine`) — comes through here instead.
//

import KSPlayer
import SwiftUI

extension KSPlayerEngineView {
    /// Seek to `time` — or, on a catch-up programme, hand the seek to the host,
    /// which opens a new segment instead.
    func seek(to time: TimeInterval) {
        if catchupRouter.route(.to(time)) { return }
        coordinator.seek(time: time)
    }

    /// Skip by `seconds` — or, on a catch-up programme, hand the skip to the
    /// host.
    func skip(by seconds: TimeInterval) {
        if catchupRouter.route(.by(seconds)) { return }
        coordinator.skip(interval: Int(seconds))
    }

    /// Point the router at the stream on screen and the host's handler.
    func loadCatchupRouter() {
        catchupRouter.load(media)
        catchupRouter.onSeek = onCatchupSeek
    }

    /// Back to a fresh session's baseline for a newly swapped-in stream: both
    /// bodies run this, so a swap re-arms the startup watchdog and raises the
    /// spinner until the new stream's first frame on every platform. The
    /// controls go with `hasStartedPlayback` (they would otherwise offer a Play
    /// button over a stream that is only loading) — except for a catch-up seek
    /// within one programme, where they stay up so the viewer can keep seeking.
    /// A segment that never starts still ends in the startup watchdog's error
    /// overlay or an engine fallback.
    func resetForNewStream(_ newMedia: PlayableMedia) {
        let isCatchupSeek = newMedia.catchup?.isSameProgramme(as: catchupRouter.media?.catchup) == true
        isCatchupSegmentLoading = isCatchupSeek && (hasStartedPlayback || isCatchupSegmentLoading)
        catchupRouter.load(newMedia)
        isSeeking = false
        seekPosition = 0
        hasStartedPlayback = false
        hasSeenReadyToPlay = false
        isBuffering = true
        loadFailed = false
        tick.reset()
        cancelStallWatchdog()
        reconnector.reset()
        #if os(tvOS)
            isPanelOpen = false
            engine.reset()
        #endif
        startStartupWatchdog()
        resetHideTimer()
    }
}

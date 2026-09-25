import Foundation
import Observation

/// The full-screen player's high-frequency state: elapsed time and total
/// duration.
///
/// Kept as an `@Observable` reference type so that ticking the clock several
/// times a second invalidates *only* the views that actually read it — the
/// scrubber and time labels — and nothing else. Were these scalars `@State` on
/// the host (`FullScreenPlayerView`), every tick would re-evaluate the host's
/// body, rebuild the engine view, and re-run KSPlayer's option setup, which was
/// the dominant source of player UI lag on Apple TV's weaker CPU. The host owns
/// the clock and hands bindings to its children, but never reads `current` /
/// `duration` in its own body, so it is not invalidated by playback ticks.
@Observable
final class PlaybackClock {
    var current: TimeInterval = 0 {
        didSet {
            // A zero callback is common while a resumed stream is still
            // preparing. Once an engine has reported a real position, zero is
            // meaningful again (for example after seeking back to the start).
            if current.isFinite, current > 0 {
                hasEstablishedPosition = true
            }
        }
    }

    var duration: TimeInterval = 0
    private(set) var hasEstablishedPosition = false
    /// Low-frequency transport state shared with the host for lifecycle work
    /// such as Trakt scrobbling. Unlike the time fields, this changes only at
    /// play/pause boundaries.
    var isPlaying = false

    /// A catch-up seek parks the clock on the segment it is heading for; the
    /// stream still on screen keeps ticking until the swap lands, and letting
    /// its playhead through would drag the scrubber back. Engine reports for
    /// this media id are dropped until one arrives from another stream.
    /// Unobserved: it gates writes, nothing renders it.
    @ObservationIgnored private var heldMediaID: String?

    /// Reset to zero when the host swaps to a different stream.
    func reset() {
        current = 0
        duration = 0
        isPlaying = false
        hasEstablishedPosition = false
        heldMediaID = nil
    }

    /// `reset()`, then place the clock where `media` starts on its programme
    /// timeline. The same as `reset()` for anything but catch-up.
    func reset(for media: PlayableMedia) {
        reset()
        rebase(onto: media)
    }

    /// Move to a new catch-up segment of the programme already on screen: the
    /// playhead jumps to the segment's offset, the programme's duration stays,
    /// and play state and any hold survive. A no-op for other media.
    func rebase(onto media: PlayableMedia) {
        guard let timeline = media.catchup else { return }
        current = timeline.offset
        if timeline.duration > 0 { duration = timeline.duration }
    }

    /// Ignore engine reports from `mediaID` until a different stream reports.
    func holdEngineReports(from mediaID: String) {
        heldMediaID = mediaID
    }

    func releaseHold() {
        heldMediaID = nil
    }

    /// The one place an engine's playhead reaches the clock: mapped onto
    /// `media`'s timeline (programme time for catch-up, unchanged otherwise)
    /// and dropped while a catch-up seek holds `media`'s reports.
    func applyEngine(position: TimeInterval, of media: PlayableMedia?) {
        guard position.isFinite else { return }
        if let heldMediaID {
            guard heldMediaID != media?.id else { return }
            self.heldMediaID = nil
        }
        current = media?.timelinePosition(position) ?? position
    }

    /// The engine's reported duration, mapped like `applyEngine(position:of:)`.
    func applyEngine(duration total: TimeInterval, of media: PlayableMedia?) {
        guard total.isFinite, total > 0 else { return }
        duration = media?.timelineDuration(total) ?? total
    }

    /// Uses saved resume progress only while the engine is still emitting its
    /// preparatory zero. After its first real time sample, always trust the
    /// playhead—including a later seek backwards below the resume position.
    func elapsed(fallback: TimeInterval) -> TimeInterval {
        hasEstablishedPosition ? current : fallback
    }
}

/// Mutable scratch written from KSPlayer's 10 Hz `onPlay` callback — see
/// `KSPlayerEngineView.tick` for why this lives in a reference type outside
/// SwiftUI's change tracking.
final class PlaybackTickScratch {
    /// Last playhead position seen in `onPlay`, used to detect that frames are
    /// actually advancing. `-1` until the first sample. See `notePlaybackProgress`.
    var lastPlayhead: TimeInterval = -1
    /// When a runaway live A/V clock split was first observed, `nil` while in
    /// sync (see `noteClockDrift` — frozen image with healthy audio after an
    /// HLS timestamp discontinuity).
    var driftSince: TimeInterval?
    /// When the last drift-triggered stream rebuild fired, for the re-fire
    /// cooldown in `noteClockDrift`.
    var lastDriftRecovery: TimeInterval = -.infinity

    /// Back to the fresh-session baseline, for stream swaps.
    func reset() {
        lastPlayhead = -1
        driftSince = nil
        lastDriftRecovery = -.infinity
    }
}

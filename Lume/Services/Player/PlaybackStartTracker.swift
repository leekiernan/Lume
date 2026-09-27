//
//  PlaybackStartTracker.swift
//  Lume
//
//  The one rule every playback engine uses to decide that a stream has
//  started — its first frame is on screen. That decision disarms the startup
//  watchdog, drops the spinner and stamps QoE join time, so getting it wrong in
//  one engine means a playing stream is declared dead and the host falls back
//  to the next engine.
//
//  Each engine used to decide this its own way, off its own "playing" signal
//  alone, and each signal has a hole: VLC does not re-emit `.playing` when a
//  new media is loaded into a player that is already playing (a catch-up seek),
//  and KSPlayer's async state callbacks can be consumed by the stream a swap
//  just replaced. The playhead has no such hole. It only advances while frames
//  are being presented, so real progress on *this* stream proves it started
//  whatever the engine's state machine said.
//
//  This is the first piece of a shared playback supervisor. The startup
//  watchdog, stall detection and the reconnect budget still live in each
//  engine and are meant to move in here later; for now it only answers "has
//  this stream started?".
//

import Foundation

/// Decides, once per stream, that playback has started.
///
/// Started means either of:
/// - **The engine's own signal** (`noteEngineStarted`) — KSPlayer's
///   `.bufferFinished`, VLC's `.playing`, AVPlayer's `.playing`, LumeEngine's
///   `.playing`. An engine whose callbacks can be stale (KSPlayer) passes
///   `requiringReady` and reports its "ready" state through `noteEngineReady`,
///   so a leftover callback from the previous stream is ignored.
/// - **The playhead advancing** (`notePlayhead`) by `proofAdvance` past the
///   lowest sample seen on this stream. A lower later sample re-bases, because
///   the stream a swap replaced can still report first; a forward jump of more
///   than `maxSampleStep` between two samples re-bases too, because that is a
///   seek (a resume, a stale sample from another position), not playback.
///
/// Each note returns the `Proof` exactly once per stream — on the call that
/// flips it to started — so the caller runs its first-frame side effects
/// (disarm the watchdog, clear the spinner, `PlaybackQoE.noteFirstFrame`)
/// once. `beginStream()` starts the next stream from scratch.
///
/// A value type with no clock and no engine state, so it is fed from whatever
/// time callback each engine has and tested without one.
nonisolated struct PlaybackStartTracker: Equatable {
    /// What proved the stream started.
    nonisolated enum Proof: Equatable {
        /// The engine reported that it is playing.
        case engine
        /// The playhead advanced on this stream.
        case playhead
    }

    /// How far the playhead must advance on one stream before that alone
    /// counts as its first frame: several ticks of every engine's time
    /// callback (0.1 s KSPlayer / LumeEngine, 0.5 s AVPlayer), so one stale
    /// sample from the stream being replaced can't pass for progress.
    static let defaultProofAdvance: TimeInterval = 0.5

    /// The largest forward step between two consecutive samples that still
    /// counts as playback. Every engine samples at least every half second, so
    /// a bigger step is a seek or a sample from somewhere else, and it starts a
    /// new baseline rather than proving anything.
    static let maxSampleStep: TimeInterval = 3

    let proofAdvance: TimeInterval

    /// Whether this stream has started. Once true it stays true until
    /// `beginStream()`.
    private(set) var hasStarted = false
    /// Whether the engine reported its "ready" state for this stream — the
    /// gate a `requiringReady` engine signal needs (KSPlayer's `.readyToPlay`).
    /// Cleared by `beginStream()` and `beginReconnect()`.
    private(set) var isEngineReady = false

    /// The sample the advance is measured from; `nil` until the first sample.
    private var baseline: TimeInterval?
    /// The previous sample, for the jump check; `nil` until the first sample.
    private var lastSample: TimeInterval?

    init(proofAdvance: TimeInterval = Self.defaultProofAdvance) {
        self.proofAdvance = proofAdvance
    }

    // MARK: - Stream boundaries

    /// A new stream is loading (open, swap, catch-up segment, Try Again,
    /// engine rebuild): forget everything about the last one.
    mutating func beginStream() {
        hasStarted = false
        isEngineReady = false
        discardSamples()
    }

    /// The same stream is re-opening after a drop. Whether it had started is
    /// kept — a reconnect is not a new join — but the ready gate and the
    /// playhead baseline belong to the connection that just went away.
    mutating func beginReconnect() {
        isEngineReady = false
        discardSamples()
    }

    /// The engine is about to jump the playhead itself (a resume or user
    /// seek): the next sample starts a fresh baseline.
    mutating func discardSamples() {
        baseline = nil
        lastSample = nil
    }

    // MARK: - Signals

    /// The engine reached its "ready" state on this stream (KSPlayer's
    /// `.readyToPlay`), arming `noteEngineStarted(requiringReady: true)`.
    mutating func noteEngineReady() {
        isEngineReady = true
    }

    /// The engine reported that it is playing. With `requiringReady`, the
    /// signal counts only once `noteEngineReady()` has been seen on this
    /// stream — a stale callback from the previous stream arrives before it.
    ///
    /// - Returns: `.engine` if this call started the stream, `nil` otherwise.
    @discardableResult
    mutating func noteEngineStarted(requiringReady: Bool = false) -> Proof? {
        guard !requiringReady || isEngineReady else { return nil }
        return markStarted(.engine)
    }

    /// A playhead sample from the engine's time callback, in the stream's own
    /// seconds. Non-finite samples are ignored.
    ///
    /// - Returns: `.playhead` if this sample started the stream, `nil`
    ///   otherwise.
    @discardableResult
    mutating func notePlayhead(_ position: TimeInterval) -> Proof? {
        guard position.isFinite else { return nil }
        defer { lastSample = position }
        guard let baseline, let lastSample, position - lastSample <= Self.maxSampleStep else {
            baseline = position
            return nil
        }
        if position < baseline {
            self.baseline = position
            return nil
        }
        guard position - baseline >= proofAdvance else { return nil }
        return markStarted(.playhead)
    }

    private mutating func markStarted(_ proof: Proof) -> Proof? {
        guard !hasStarted else { return nil }
        hasStarted = true
        return proof
    }
}

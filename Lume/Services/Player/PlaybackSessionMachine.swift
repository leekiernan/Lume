//
//  PlaybackSessionMachine.swift
//  Lume
//
//  What a full-screen playback session is doing, as one explicit state rather
//  than each engine's mix of started / buffering / playing / failed flags —
//  and what follows from each change: the Trakt scrobble, saving progress,
//  falling back to the next engine.
//
//  The distinction that matters most is *why* frames stopped. A viewer's pause
//  is `paused` (Trakt hears "pause", progress is saved); a stall is
//  `rebuffering` (neither — to the viewer and to Trakt it is still playback).
//  Engines used to be read through a single "is playing" flag that couldn't
//  tell the two apart.
//
//  Pure: the host (`FullScreenPlayerView`) feeds events in and performs the
//  effects handed back; engines report their flags through
//  `View.reportsPlayback(to:…)`.
//

import Foundation

struct PlaybackSessionMachine: Equatable {
    /// Why an engine is starting a stream.
    enum Cause: Equatable {
        case open
        case swap
        case catchupSegment
        case fallback
        case retry
    }

    enum Failure: Equatable {
        /// The stream never produced a frame on any engine.
        case startup
        /// It played, then the engine gave up on it.
        case playback
        /// A Stalker link couldn't be resolved.
        case resolve
    }

    enum State: Equatable {
        /// No stream: before the first open, or between leaving one stream and
        /// starting the next.
        case idle
        case resolving
        case starting(Cause)
        case playing
        /// The viewer paused.
        case paused
        /// Started, waiting on data. Still playback as far as anyone outside
        /// the player is concerned.
        case rebuffering
        case failed(Failure)
        case closed
    }

    /// One engine's view of its stream, reported whenever a flag changes.
    struct EngineReport: Equatable {
        var started: Bool
        var buffering: Bool
        var playing: Bool
        var failed: Bool
    }

    enum Leave: Equatable {
        /// Another stream is about to replace this one.
        case swap
        case dismiss
        /// The app left the foreground; the session carries on.
        case background
    }

    enum Event: Equatable {
        case resolving
        case resolveFailed
        /// An engine is about to start a stream.
        case starting(PlayerEngineKind, Cause)
        case reported(PlayerEngineKind, EngineReport)
        /// The engine couldn't start the stream. `canFallBack` is decided by
        /// the host at that moment, not when the engine was built — an AirPlay
        /// route arriving in between changes the answer.
        case failedToStart(PlayerEngineKind, canFallBack: Bool)
        case leave(Leave)
    }

    enum ScrobbleAction: Equatable {
        case start
        case pause
        case stop
    }

    enum Effect: Equatable {
        case scrobble(ScrobbleAction)
        case persistProgress
        case fallBackToNextEngine
    }

    private(set) var state: State = .idle
    /// The engine the session is on. Reports from any other engine — one being
    /// torn down after a fallback overlaps the next one's first frames — are
    /// ignored.
    private(set) var engine: PlayerEngineKind?

    /// Whether the engine should raise its failure overlay: the session failed
    /// with nothing left to try.
    var showsFailure: Bool {
        if case .failed(.startup) = state { return true }
        return false
    }

    /// Applies `event`. Returns the effects to perform, or nil when the event
    /// doesn't apply (a report from an engine the session has moved on from,
    /// anything after close) and the state is unchanged.
    mutating func handle(_ event: Event) -> [Effect]? {
        guard state != .closed else { return nil }
        switch event {
        case .resolving:
            state = .resolving
            return []
        case .resolveFailed:
            state = .failed(.resolve)
            return []
        case let .starting(engine, cause):
            self.engine = engine
            state = .starting(cause)
            return []
        case let .reported(engine, report):
            // Between streams, whatever the engine reports belongs to the one
            // being left — a quick second surf lands its first frame here.
            guard engine == self.engine, state != .idle else { return nil }
            return apply(report)
        case let .failedToStart(engine, canFallBack):
            return failedToStart(engine, canFallBack: canFallBack)
        case let .leave(reason):
            return leave(reason)
        }
    }

    private mutating func failedToStart(_ engine: PlayerEngineKind, canFallBack: Bool) -> [Effect]? {
        guard engine == self.engine, case .starting = state else { return nil }
        if canFallBack {
            state = .starting(.fallback)
            return [.fallBackToNextEngine]
        }
        state = .failed(.startup)
        return []
    }

    private mutating func leave(_ reason: Leave) -> [Effect] {
        switch reason {
        case .background:
            return [.persistProgress]
        case .swap:
            state = .idle
            return [.scrobble(.stop), .persistProgress]
        case .dismiss:
            state = .closed
            engine = nil
            return [.scrobble(.stop), .persistProgress]
        }
    }

    private mutating func apply(_ report: EngineReport) -> [Effect] {
        let previous = state
        let next = Self.state(after: report, from: previous)
        guard next != previous else { return [] }
        state = next
        return Self.effects(from: previous, to: next)
    }

    /// What an engine report means, given where the session was.
    private static func state(after report: EngineReport, from previous: State) -> State {
        let startingCause: Cause? = if case let .starting(cause) = previous { cause } else { nil }
        if report.failed {
            return .failed(report.started ? .playback : .startup)
        }
        if !report.started {
            // Not started: still joining — or, from a failure, the viewer's
            // Try Again.
            return .starting(startingCause ?? .retry)
        }
        if report.buffering {
            // Started but still buffering while starting is the first frame
            // arriving in two writes, not a stall.
            return startingCause.map(State.starting) ?? .rebuffering
        }
        return report.playing ? .playing : .paused
    }

    private static func effects(from previous: State, to next: State) -> [Effect] {
        switch (previous, next) {
        case (_, .playing):
            [.scrobble(.start)]
        case (.playing, .paused), (.rebuffering, .paused):
            // A pause is a natural boundary to save the position at, and it's
            // off the playback path: nothing is rendering.
            [.scrobble(.pause), .persistProgress]
        case (.playing, .failed), (.paused, .failed), (.rebuffering, .failed):
            [.scrobble(.stop)]
        default:
            []
        }
    }
}

// MARK: - Journal names

extension PlaybackSessionMachine.State {
    var logName: String {
        switch self {
        case .idle: "idle"
        case .resolving: "resolving"
        case let .starting(cause): "starting(\(cause))"
        case .playing: "playing"
        case .paused: "paused"
        case .rebuffering: "rebuffering"
        case let .failed(failure): "failed(\(failure))"
        case .closed: "closed"
        }
    }
}

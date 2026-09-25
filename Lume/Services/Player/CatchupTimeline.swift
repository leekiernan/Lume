//
//  CatchupTimeline.swift
//  Lume
//
//  Where a catch-up (timeshift) stream sits inside the programme it replays,
//  and how a seek on that programme turns into a new stream.
//
//  A timeshift URL names a wall-clock minute to start from and serves the
//  archive from there, live-style: panels only start cleanly on the minute
//  boundary in the URL, so a byte-seek inside one long stream lands wherever
//  the demuxer happens to resync — forwards it "jumps around", backwards it
//  usually stalls for good. Instead the player keeps the programme's own
//  timeline on screen and answers every seek by opening a fresh URL at the
//  nearest drop-in minute (a *segment*). These types are the pure half of
//  that: the host (`FullScreenPlayerView+Catchup`) only reads the clock and
//  swaps the stream.
//

import Foundation

/// A catch-up stream's place inside its programme.
///
/// The programme timeline starts at `origin` — the programme's start floored to
/// a wall-clock minute, which is the first instant a timeshift URL can name —
/// so every drop-in point is a whole number of minutes into it. EPG starts are
/// minute-aligned in practice, which makes `origin` the programme start itself.
nonisolated struct CatchupTimeline: Hashable, Codable {
    /// The `LiveStream.id` the archive belongs to.
    let streamID: String
    let programmeTitle: String
    let programmeStart: Date
    let programmeEnd: Date
    /// The minute-aligned wall-clock instant this segment's URL starts at.
    let segmentStart: Date

    /// Programme time zero: the first minute a timeshift URL can start from.
    var origin: Date {
        Self.minuteFloor(programmeStart)
    }

    /// Where this segment starts on the programme timeline.
    var offset: TimeInterval {
        max(0, segmentStart.timeIntervalSince(origin))
    }

    /// The programme's scheduled length on its own timeline.
    var duration: TimeInterval {
        max(0, programmeEnd.timeIntervalSince(origin))
    }

    /// Whether `other` replays the same programme on the same channel — the
    /// case where swapping to it is a seek rather than a new stream.
    func isSameProgramme(as other: CatchupTimeline?) -> Bool {
        guard let other else { return false }
        return streamID == other.streamID
            && programmeStart == other.programmeStart
            && programmeEnd == other.programmeEnd
    }

    /// Programme time for a playhead the engine reports relative to this
    /// segment's own start.
    func timelinePosition(_ enginePosition: TimeInterval) -> TimeInterval {
        let position = offset + enginePosition
        return duration > 0 ? min(max(position, 0), duration) : max(position, 0)
    }

    /// The segment-relative playhead for a programme time — what an engine
    /// resuming inside this segment (reconnect, AirPlay hand-off) must be given.
    func enginePosition(_ timelinePosition: TimeInterval) -> TimeInterval {
        max(0, timelinePosition - offset)
    }

    /// `date` truncated to its wall-clock minute — the granularity of a
    /// timeshift URL's start.
    static func minuteFloor(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}

/// A seek on a catch-up programme, in programme time.
nonisolated enum CatchupSeek: Hashable {
    // Read as prose at the call site: `.to(position)`, `.by(delta)`.
    // swiftlint:disable identifier_name
    /// Jump to an absolute programme position (scrubber, restart, remote
    /// change-position).
    case to(TimeInterval)
    /// Move relative to where playback is (skip buttons, arrow keys).
    case by(TimeInterval)
    // swiftlint:enable identifier_name
}

/// Turns a `CatchupSeek` into the segment to open. Pure, so the rules the
/// player follows are the ones the tests pin.
nonisolated enum CatchupSeekPlanner {
    /// The spacing of drop-in points: a timeshift URL starts on a minute.
    static let step: TimeInterval = 60

    /// `offset` floored to a whole drop-in step.
    static func floorToStep(_ offset: TimeInterval) -> TimeInterval {
        guard offset.isFinite, offset > 0 else { return 0 }
        return (offset / step).rounded(.down) * step
    }

    /// The last drop-in point a segment can start from at `now`: a minute
    /// before the programme's end once it has finished, or a minute behind
    /// real time while it is still airing (a segment can't start in the
    /// future). Never below zero.
    static func latestStartableOffset(for timeline: CatchupTimeline, now: Date) -> TimeInterval {
        let aired = now.timeIntervalSince(timeline.origin)
        return floorToStep(min(timeline.duration, aired) - step)
    }

    /// The programme offset of the segment to open for `seek`, or `nil` when
    /// the request can't move playback anywhere useful (a forward press at the
    /// latest drop-in point).
    ///
    /// - `current`: the programme clock now.
    /// - `pendingTarget`: the segment a still-debounced earlier seek chose, so
    ///   rapid presses accumulate from where the viewer is headed rather than
    ///   from the frame still on screen.
    ///
    /// Rules: the target is clamped to `0 ... latestStartableOffset` and
    /// floored to its drop-in minute. A backward request that lands inside the
    /// current minute restarts it. A forward request always moves to at least
    /// the next drop-in point after the one playback is in, so a forward press
    /// never plays anything already seen.
    static func plan(
        _ seek: CatchupSeek,
        current: TimeInterval,
        pendingTarget: TimeInterval?,
        timeline: CatchupTimeline,
        now: Date
    ) -> TimeInterval? {
        let base = pendingTarget ?? (current.isFinite ? current : 0)
        let requested: TimeInterval
        let isForward: Bool
        switch seek {
        case let .by(delta):
            requested = base + delta
            isForward = delta > 0
        case let .to(position):
            requested = position
            isForward = position > base
        }
        guard requested.isFinite else { return nil }
        let latest = latestStartableOffset(for: timeline, now: now)
        var target = floorToStep(min(max(requested, 0), latest))
        guard isForward else { return target }

        // The drop-in point playback is in: the pending segment if a seek is
        // already under way, otherwise the minute the playhead has reached.
        let reference = max(pendingTarget ?? timeline.offset, floorToStep(base))
        target = min(max(target, reference + step), latest)
        return target > reference ? target : nil
    }
}

// MARK: - PlayableMedia

extension PlayableMedia {
    /// Programme time for a playhead an engine reports. The identity for
    /// everything but catch-up, whose engines report relative to the segment.
    nonisolated func timelinePosition(_ enginePosition: TimeInterval) -> TimeInterval {
        catchup?.timelinePosition(enginePosition) ?? enginePosition
    }

    /// The duration the player shows. A catch-up segment's own length (to the
    /// end of the programme, or whatever the provider reports) is not the
    /// programme's, so the programme's scheduled length wins.
    nonisolated func timelineDuration(_ engineDuration: TimeInterval) -> TimeInterval {
        guard let catchup, catchup.duration > 0 else { return engineDuration }
        return catchup.duration
    }

    /// The engine-relative playhead for a programme time — the inverse of
    /// `timelinePosition`, for anything that re-opens the current stream at a
    /// position (reconnect, AirPlay hand-off, resume snapshots).
    nonisolated func enginePosition(_ timelinePosition: TimeInterval) -> TimeInterval {
        catchup?.enginePosition(timelinePosition) ?? timelinePosition
    }

    /// The transport skip step. Catch-up skips a whole drop-in minute: a
    /// shorter step would only restart the minute already playing.
    nonisolated func skipInterval(default standard: TimeInterval) -> TimeInterval {
        catchup != nil ? CatchupSeekPlanner.step : standard
    }

    /// Identity of the viewing session this stream belongs to. The same as
    /// `id`, except that every segment of one catch-up programme shares it, so
    /// per-session work (Now Playing, neighbours, the tvOS overlay's content
    /// lookups) survives a seek instead of re-running for each segment.
    nonisolated var playbackSessionID: String {
        guard let catchup else { return id }
        return "catchup-\(catchup.streamID)-\(Int(catchup.programmeStart.timeIntervalSince1970))"
    }
}

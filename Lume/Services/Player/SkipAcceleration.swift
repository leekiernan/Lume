//
//  SkipAcceleration.swift
//  Lume
//
//  Repeated presses of a skip button in one direction take bigger steps, so
//  crossing an episode doesn't take a hundred presses of 10 s. The steps are
//  the same everywhere — 10 s, 30 s, 1 min, 3 min, then 5 min a press — from
//  the content's own finest step up: catch-up archives are split by the
//  minute, so they start at 1 min and climb 1, 3, 5. A pause or a change of
//  direction starts again at the finest step.
//
//  A small pure state machine: the overlay holds one and asks it for each
//  press. It also keeps where the run started and its running total, so the
//  indicator shows how far the whole run has gone — the last press's step
//  alone reads "+5 min" after a run of nearly 10.
//

import Foundation

nonisolated struct SkipAcceleration: Equatable {
    /// The shared steps, finest first. A content's ladder is its own base
    /// step followed by every shared step above it; the last repeats.
    static let steps: [TimeInterval] = [10, 30, 60, 180, 300]
    /// How soon the next press must come to keep climbing.
    static let window: TimeInterval = 1

    /// One press: its own step, and the run it belongs to so far.
    struct Press: Equatable {
        let step: TimeInterval
        /// Where the run started and where it now lands, clamped to the
        /// content — so near either end the total is the real distance.
        let origin: TimeInterval
        let target: TimeInterval

        var total: TimeInterval {
            target - origin
        }
    }

    private var forward: Bool?
    private var level = 0
    private var lastPress: Date?
    private var origin: TimeInterval = 0
    private var runTotal: TimeInterval = 0

    static func ladder(base: TimeInterval) -> [TimeInterval] {
        [base] + steps.filter { $0 > base }
    }

    /// A press from `position`: its signed step, advancing the ladder when it
    /// continues a quick run in the same direction, and where the run lands
    /// within `0 ... duration` (open-ended while the duration is unknown).
    mutating func press(
        forward: Bool, base: TimeInterval, from position: TimeInterval,
        duration: TimeInterval, at now: Date = Date()
    ) -> Press {
        let ladder = Self.ladder(base: base)
        let continuing = self.forward == forward
            && lastPress.map { now.timeIntervalSince($0) <= Self.window } == true
        level = continuing ? min(level + 1, ladder.count - 1) : 0
        self.forward = forward
        lastPress = now
        let step = forward ? ladder[level] : -ladder[level]
        if !continuing {
            origin = position.isFinite ? position : 0
            runTotal = 0
        }
        runTotal += step
        let end = duration > 0 ? duration : .infinity
        return Press(step: step, origin: origin, target: min(max(origin + runTotal, 0), end))
    }

    /// How a distance reads on screen: "+3 min", "−9 min, 40 sec" (localised).
    static func label(for distance: TimeInterval) -> String {
        let magnitude = Duration.seconds(abs(distance).rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        return (distance < 0 ? "−" : "+") + magnitude
    }

    /// A position in the content, as the progress bar shows it: "12:34".
    static func timeLabel(for position: TimeInterval) -> String {
        let clamped = position.isFinite ? max(position, 0).rounded(.down) : 0
        let pattern: Duration.TimeFormatStyle.Pattern = clamped >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(clamped).formatted(.time(pattern: pattern))
    }
}

/// How far the current skip run has gone and where it lands, shown until the
/// run ends. Its own identity, so the same total twice still refreshes it.
nonisolated struct SkipBadge: Equatable {
    /// How long it stays after the last press, or after the seek finished
    /// loading: past the run's window, and long enough to read.
    static let dwell: TimeInterval = 2
    /// The most it stays through a buffer before the spinner takes over.
    static let longest: TimeInterval = 8

    /// What its dismissal waits on: the latest press, and the buffering.
    struct Dwell: Equatable {
        let badge: UUID?
        let buffering: Bool
    }

    let id = UUID()
    let press: SkipAcceleration.Press
    let shownAt: Date

    init(press: SkipAcceleration.Press, shownAt: Date = Date()) {
        self.press = press
        self.shownAt = shownAt
    }

    /// How much longer it stays: through a buffer up to `longest` from when it
    /// appeared, otherwise `dwell` from now.
    func remainingDwell(buffering: Bool, at now: Date = Date()) -> TimeInterval {
        buffering ? max(Self.longest - now.timeIntervalSince(shownAt), 0) : Self.dwell
    }

    /// Keeps one indicator on screen through a run in one direction, so its
    /// number climbs in place rather than the panel re-appearing each press.
    /// From the step, not the total: a run held at the start still reads as
    /// going backwards.
    var forward: Bool {
        press.step > 0
    }
}

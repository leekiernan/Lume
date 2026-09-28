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
//  press's step.
//

import Foundation

nonisolated struct SkipAcceleration: Equatable {
    /// The shared steps, finest first. A content's ladder is its own base
    /// step followed by every shared step above it; the last repeats.
    static let steps: [TimeInterval] = [10, 30, 60, 180, 300]
    /// How soon the next press must come to keep climbing.
    static let window: TimeInterval = 1

    private var forward: Bool?
    private var level = 0
    private var lastPress: Date?

    static func ladder(base: TimeInterval) -> [TimeInterval] {
        [base] + steps.filter { $0 > base }
    }

    /// The signed step for a press, advancing the ladder when it continues a
    /// quick run in the same direction.
    mutating func step(forward: Bool, base: TimeInterval, at now: Date = Date()) -> TimeInterval {
        let ladder = Self.ladder(base: base)
        let continuing = self.forward == forward
            && lastPress.map { now.timeIntervalSince($0) <= Self.window } == true
        level = continuing ? min(level + 1, ladder.count - 1) : 0
        self.forward = forward
        lastPress = now
        return forward ? ladder[level] : -ladder[level]
    }

    /// How a step reads on screen: "+3 min", "−10 sec" (localised).
    static func label(for step: TimeInterval) -> String {
        let magnitude = Duration.seconds(abs(step))
            .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
        return (step < 0 ? "−" : "+") + magnitude
    }
}

/// The step a skip press just took, shown on the button until the run ends.
/// Its own identity, so the same step twice still refreshes the badge.
nonisolated struct SkipBadge: Equatable {
    let id = UUID()
    let step: TimeInterval

    /// Keeps one indicator on screen through a run in one direction, so its
    /// number climbs in place rather than the panel re-appearing each press.
    var forward: Bool {
        step > 0
    }
}

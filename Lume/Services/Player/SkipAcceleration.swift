//
//  SkipAcceleration.swift
//  Lume
//
//  Repeated presses of a skip button in one direction take bigger steps, so
//  crossing an episode doesn't take a hundred presses of 10 s: 10, 30, 60,
//  180, then 300 s a press while the presses keep coming. A pause or a change
//  of direction starts again at the base step.
//
//  A small pure state machine: the overlay holds one and asks it for each
//  press's step.
//

import Foundation

nonisolated struct SkipAcceleration: Equatable {
    /// Multiples of the base step, climbed one per quick press; the last one
    /// repeats. A 10 s base gives 10, 30, 60, 180, 300 s.
    static let ladder: [Double] = [1, 3, 6, 18, 30]
    /// How soon the next press must come to keep climbing.
    static let window: TimeInterval = 1

    private var forward: Bool?
    private var level = 0
    private var lastPress: Date?

    /// The signed step for a press, advancing the ladder when it continues a
    /// quick run in the same direction.
    mutating func step(forward: Bool, base: TimeInterval, at now: Date = Date()) -> TimeInterval {
        let continuing = self.forward == forward
            && lastPress.map { now.timeIntervalSince($0) <= Self.window } == true
        level = continuing ? min(level + 1, Self.ladder.count - 1) : 0
        self.forward = forward
        lastPress = now
        let magnitude = base * Self.ladder[level]
        return forward ? magnitude : -magnitude
    }
}

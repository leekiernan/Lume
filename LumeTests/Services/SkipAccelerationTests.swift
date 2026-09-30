//
//  SkipAccelerationTests.swift
//  LumeTests
//
//  Quick repeated skip presses go further: the run lands on the ladder's
//  rungs, and each press moves only the difference.
//

import Foundation
@testable import Lume
import Testing

struct SkipAccelerationTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func run(
        _ acceleration: inout SkipAcceleration, presses: Int, forward: Bool = true,
        base: TimeInterval = 10, from position: TimeInterval = 600, duration: TimeInterval = 3600
    ) -> [SkipAcceleration.Press] {
        (0 ..< presses).map { press in
            acceleration.press(
                forward: forward, base: base, from: position, duration: duration,
                at: start.addingTimeInterval(Double(press) * 0.4)
            )
        }
    }

    /// The nth press lands on the nth rung — not on the sum of the rungs —
    /// and past the top each press adds the top step.
    @Test func `quick presses land on 10 s, 30 s, 1, 3, 5, 10, 15 min`() {
        var acceleration = SkipAcceleration()
        let presses = run(&acceleration, presses: 7, from: 600)
        #expect(presses.map(\.total) == [10, 30, 60, 180, 300, 600, 900])
        #expect(presses.last?.origin == 600)
        #expect(presses.last?.target == 1500)
    }

    /// A relative seek per press has to arrive at the same place.
    @Test func `each press moves only the difference`() {
        var acceleration = SkipAcceleration()
        let steps = run(&acceleration, presses: 7).map(\.step)
        #expect(steps == [10, 20, 30, 120, 120, 300, 300])
        #expect(steps.reduce(0, +) == 900)
    }

    @Test func `the run stops at either end of the content`() {
        var forward = SkipAcceleration()
        let late = run(&forward, presses: 4, from: 3500, duration: 3600)
        #expect(late.last?.target == 3600)
        #expect(late.last?.total == 100)

        var backward = SkipAcceleration()
        let early = run(&backward, presses: 3, forward: false, from: 50)
        #expect(early.last?.target == 0)
        #expect(early.last?.total == -50)
        #expect(SkipBadge(press: early[2]).forward == false)
    }

    @Test func `an unknown duration leaves the run open-ended`() {
        var acceleration = SkipAcceleration()
        #expect(run(&acceleration, presses: 2, from: 0, duration: 0).last?.target == 30)
    }

    @Test func `a pause starts a new run at the base step`() {
        var acceleration = SkipAcceleration()
        _ = run(&acceleration, presses: 2, from: 600)
        let next = acceleration.press(
            forward: true, base: 10, from: 700, duration: 3600, at: start.addingTimeInterval(3)
        )
        #expect(next.step == 10)
        #expect(next.origin == 700)
        #expect(next.total == 10)
    }

    @Test func `changing direction starts again, backwards`() {
        var acceleration = SkipAcceleration()
        _ = run(&acceleration, presses: 2)
        let back = (0 ..< 2).map { press in
            acceleration.press(
                forward: false, base: 10, from: 640, duration: 3600,
                at: start.addingTimeInterval(0.6 + Double(press) * 0.3)
            )
        }
        #expect(back.map(\.step) == [-10, -20])
        #expect(back.last?.total == -30)
        #expect(back.last?.origin == 640)
    }

    /// Catch-up archives are split by the minute: the ladder starts there and
    /// meets VOD's steps from then on.
    @Test func `a coarser base starts higher on the same steps`() {
        #expect(SkipAcceleration.ladder(base: 10) == [10, 30, 60, 180, 300])
        #expect(SkipAcceleration.ladder(base: 60) == [60, 180, 300])
        #expect(SkipAcceleration.ladder(base: 15) == [15, 30, 60, 180, 300])
        var acceleration = SkipAcceleration()
        #expect(run(&acceleration, presses: 4, base: 60).map(\.total) == [60, 180, 300, 600])
    }

    @Test func `the badge reads the distance with its direction`() {
        #expect(SkipAcceleration.label(for: 180).hasPrefix("+"))
        #expect(SkipAcceleration.label(for: -10).hasPrefix("−"))
    }

    @Test func `the landing time reads like the progress bar`() {
        #expect(SkipAcceleration.timeLabel(for: 754).hasSuffix("34"))
        #expect(SkipAcceleration.timeLabel(for: 754).hasPrefix("12"))
        #expect(SkipAcceleration.timeLabel(for: 3725).hasPrefix("1"))
        #expect(SkipAcceleration.timeLabel(for: -5) == SkipAcceleration.timeLabel(for: 0))
    }

    /// The indicator stays through the seek's buffer — the spinner steps
    /// aside for it — but not for ever.
    @Test func `the indicator waits out a buffer, up to a limit`() {
        var acceleration = SkipAcceleration()
        let badge = SkipBadge(press: run(&acceleration, presses: 1)[0], shownAt: start)
        #expect(badge.remainingDwell(buffering: false, at: start.addingTimeInterval(5)) == SkipBadge.dwell)
        #expect(badge.remainingDwell(buffering: true, at: start.addingTimeInterval(3)) == SkipBadge.longest - 3)
        #expect(badge.remainingDwell(buffering: true, at: start.addingTimeInterval(20)) == 0)
    }
}

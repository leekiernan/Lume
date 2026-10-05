//
//  OutroTriggerTests.swift
//  LumeTests
//
//  Covers `OutroTrigger.armTime`: the unknown-duration guard, every sanity
//  check that rejects IntroDB data which doesn't match the provider's encode,
//  the two-minute cap on the fallback, and the 90% floor on trusted credits.
//

import Foundation
@testable import Lume
import Testing

struct OutroTriggerTests {
    private let duration: TimeInterval = 1000

    @Test func `no outro falls back to fraction`() {
        #expect(OutroTrigger.armTime(outro: nil, duration: duration) == 900)
    }

    @Test(arguments: [
        (duration: 600.0, armTime: 540.0), // ten-minute short: final minute
        (duration: 1200.0, armTime: 1080.0), // cap boundary: final two minutes
        (duration: 1201.0, armTime: 1081.0),
        (duration: 1800.0, armTime: 1680.0),
        (duration: 3000.0, armTime: 2880.0), // fifty minutes: 48:00, not 45:00
        (duration: 7200.0, armTime: 7080.0)
    ])
    func `fallback is the final ten percent capped at two minutes`(example: (duration: TimeInterval, armTime: TimeInterval)) {
        #expect(OutroTrigger.armTime(outro: nil, duration: example.duration) == example.armTime)
    }

    @Test func `untrusted credits on a long episode use the capped fallback`() {
        let mismatched = IntroSegments.Segment(start: 2400, end: 2500)
        #expect(OutroTrigger.armTime(outro: mismatched, duration: 3000) == 2880)
    }

    @Test func `trusted credits may start before the capped fallback`() {
        let credits = IntroSegments.Segment(start: 2820, end: 3000)
        #expect(OutroTrigger.armTime(outro: credits, duration: 3000) == 2820)
    }

    @Test func `unknown duration returns nil`() {
        #expect(OutroTrigger.armTime(outro: nil, duration: 0) == nil)
        #expect(OutroTrigger.armTime(outro: nil, duration: 1) == nil)
        #expect(
            OutroTrigger.armTime(
                outro: IntroSegments.Segment(start: 960, end: 1000),
                duration: 1
            ) == nil
        )
    }

    @Test func `outro shorter than floor falls back`() {
        let outro = IntroSegments.Segment(start: 960, end: 963)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `outro starting at zero falls back`() {
        let outro = IntroSegments.Segment(start: 0, end: 60)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `outro beyond duration falls back`() {
        let outro = IntroSegments.Segment(start: 1200, end: 1260)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `outro ending far from duration falls back`() {
        // Third-party data for a different encode: credits "end" 400s before
        // this file does.
        let outro = IntroSegments.Segment(start: 540, end: 600)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `late outro arms at outro start`() {
        let outro = IntroSegments.Segment(start: 960, end: 1000)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 960)
    }

    @Test func `early outro is clamped to the fallback line`() {
        // The single most important case: an outro that starts at 80% must not
        // arm the button below the 90% watched-completion threshold.
        let outro = IntroSegments.Segment(start: 800, end: 1000)
        #expect(OutroTrigger.armTime(outro: outro, duration: duration) == 900)
    }

    @Test func `end slack boundary is inclusive`() {
        let atLimit = IntroSegments.Segment(start: 905, end: 910)
        #expect(OutroTrigger.armTime(outro: atLimit, duration: duration) == 905)

        let pastLimit = IntroSegments.Segment(start: 904, end: 909)
        #expect(OutroTrigger.armTime(outro: pastLimit, duration: duration) == 900)
    }

    @Test func `outro running past the end of the encode falls back`() {
        // A window timed against a longer cut than the one playing: the end
        // slack is negative, which must not sneak through the `<= maxEndSlack`
        // check. Without the overshoot bound this armed at 950.
        let longerCut = IntroSegments.Segment(start: 950, end: 3000)
        #expect(OutroTrigger.armTime(outro: longerCut, duration: duration) == 900)
    }

    @Test func `outro overshooting by rounding is still trusted`() {
        // A second or two past the reported duration is ordinary rounding
        // between the container and the engine, not a mismatched encode.
        let rounding = IntroSegments.Segment(start: 950, end: 1001)
        #expect(OutroTrigger.armTime(outro: rounding, duration: duration) == 950)
    }

    @Test func `delaying the prompt does not move the watched completion line`() throws {
        let duration: TimeInterval = 3000
        let armed = try #require(OutroTrigger.armTime(outro: nil, duration: duration))
        #expect(armed == 2880)
        #expect(!WatchCompletion.isComplete(progress: 2699, duration: duration))
        #expect(WatchCompletion.isComplete(progress: 2700, duration: duration))
        #expect(WatchCompletion.isComplete(progress: armed, duration: duration))
    }

    @Test func `nothing is complete without a known duration`() {
        #expect(!WatchCompletion.isComplete(progress: 100, duration: 0))
    }
}

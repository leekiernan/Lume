//
//  SkipAccelerationTests.swift
//  LumeTests
//
//  Quick repeated skip presses take bigger steps.
//

import Foundation
@testable import Lume
import Testing

struct SkipAccelerationTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func `quick presses climb 10, 30, 60, 180, then 300 a press`() {
        var acceleration = SkipAcceleration()
        let steps = (0 ..< 7).map { press in
            acceleration.step(forward: true, base: 10, at: start.addingTimeInterval(Double(press) * 0.4))
        }
        #expect(steps == [10, 30, 60, 180, 300, 300, 300])
    }

    @Test func `a pause starts again at the base step`() {
        var acceleration = SkipAcceleration()
        _ = acceleration.step(forward: true, base: 10, at: start)
        _ = acceleration.step(forward: true, base: 10, at: start.addingTimeInterval(0.5))
        #expect(acceleration.step(forward: true, base: 10, at: start.addingTimeInterval(2)) == 10)
    }

    @Test func `changing direction starts again, backwards`() {
        var acceleration = SkipAcceleration()
        _ = acceleration.step(forward: true, base: 10, at: start)
        _ = acceleration.step(forward: true, base: 10, at: start.addingTimeInterval(0.3))
        #expect(acceleration.step(forward: false, base: 10, at: start.addingTimeInterval(0.6)) == -10)
        #expect(acceleration.step(forward: false, base: 10, at: start.addingTimeInterval(0.9)) == -30)
    }

    @Test func `the ladder scales with the base step`() {
        var acceleration = SkipAcceleration()
        _ = acceleration.step(forward: true, base: 60, at: start)
        #expect(acceleration.step(forward: true, base: 60, at: start.addingTimeInterval(0.5)) == 180)
    }
}

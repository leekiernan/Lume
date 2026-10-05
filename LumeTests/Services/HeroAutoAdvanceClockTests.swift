import Foundation
@testable import Lume
import Observation
import Testing

@MainActor
struct HeroAutoAdvanceClockTests {
    @Test func `a full bar advances once and is empty before the owner pages`() {
        let clock = HeroAutoAdvanceClock(interval: .milliseconds(100))
        #expect(!clock.tick(isPaused: false))
        #expect(clock.progress == 0.5)
        #expect(!clock.tick(isPaused: false))
        #expect(clock.progress == 1)
        #expect(clock.tick(isPaused: false))
        #expect(clock.progress == 0)
        #expect(!clock.tick(isPaused: false))
        #expect(clock.progress == 0.5)
    }

    @Test func `pausing near a full bar gives the returned slide a full dwell`() {
        let clock = HeroAutoAdvanceClock(interval: .milliseconds(100))
        _ = clock.tick(isPaused: false)
        _ = clock.tick(isPaused: false)
        #expect(!clock.tick(isPaused: true))
        #expect(clock.progress == 0)
        for _ in 0 ..< 20 {
            #expect(!clock.tick(isPaused: true))
        }
        #expect(!clock.tick(isPaused: false))
        #expect(clock.progress == 0.5)
    }

    @Test func `manual reset and single item reset do not rewrite an already empty bar`() {
        let clock = HeroAutoAdvanceClock()
        #expect(!clock.reset())
        _ = clock.tick(isPaused: false)
        #expect(clock.reset())
        #expect(!clock.reset())
        _ = clock.tick(isPaused: false)
        #expect(!clock.tick(isPaused: false, hasMultipleItems: false))
        #expect(clock.progress == 0)
        #expect(!clock.reset())
    }

    @Test func `the standard dwell uses fifty millisecond ticks and clamps its bar`() {
        let clock = HeroAutoAdvanceClock()
        #expect(HeroAutoAdvanceClock.tickInterval == .milliseconds(50))
        #expect(!clock.tick(isPaused: false))
        #expect(abs(clock.progress - 1.0 / 120) < 0.000001)
        var advanced = false
        for _ in 0 ..< 121 {
            if clock.tick(isPaused: false) {
                advanced = true
                #expect(clock.progress == 0)
                break
            }
            #expect((0 ... 1).contains(clock.progress))
        }
        #expect(advanced)
    }

    @Test func `repeated paused ticks do not invalidate the observed dots`() {
        let clock = HeroAutoAdvanceClock()
        let changes = HeroClockObservationCounter()
        observe(clock, changes: changes)
        _ = clock.tick(isPaused: false)
        #expect(changes.count == 1)
        observe(clock, changes: changes)
        _ = clock.tick(isPaused: true)
        #expect(changes.count == 2)
        observe(clock, changes: changes)
        for _ in 0 ..< 200 {
            _ = clock.tick(isPaused: true)
        }
        #expect(changes.count == 2)
    }

    private func observe(_ clock: HeroAutoAdvanceClock, changes: HeroClockObservationCounter) {
        _ = withObservationTracking { clock.progress } onChange: { changes.increment() }
    }
}

/// Observation's callback is Sendable even though these transitions are
/// synchronous; a locked counter keeps the assertion honest across executors.
private final nonisolated class HeroClockObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

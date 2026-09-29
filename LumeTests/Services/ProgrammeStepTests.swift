//
//  ProgrammeStepTests.swift
//  LumeTests
//
//  Where a catch-up programme's previous / next buttons go.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct ProgrammeStepTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func slot(_ title: String, from start: TimeInterval, to end: TimeInterval) -> EPGSlot {
        EPGSlot(title: title, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end))
    }

    @Test func `both neighbours finished and archived replay`() {
        let before = slot("News", from: -7200, to: -3600)
        let after = slot("Film", from: -1800, to: -60)
        let steps = PlayerItemNavigation.programmeSteps(previous: before, next: after, now: now) { _ in true }
        #expect(steps.previous == before)
        #expect(steps.next == .replay(after))
    }

    /// Watching the programme on air from its start: the one after hasn't
    /// finished, so next catches up to the channel live.
    @Test func `a next programme still airing goes live`() {
        let after = slot("Quiz", from: -600, to: 1200)
        let steps = PlayerItemNavigation.programmeSteps(previous: nil, next: after, now: now) { _ in true }
        #expect(steps.next == .live)
    }

    @Test func `with no guide after, next still goes live`() {
        #expect(PlayerItemNavigation.programmeSteps(previous: nil, next: nil, now: now) { _ in true }.next == .live)
    }

    @Test func `a previous programme out of the archive is not offered`() {
        let before = slot("Old", from: -9 * 86400, to: -9 * 86400 + 3600)
        let steps = PlayerItemNavigation.programmeSteps(previous: before, next: nil, now: now) { _ in false }
        #expect(steps.previous == nil)
    }
}

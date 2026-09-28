//
//  RecentResumePointsTests.swift
//  LumeTests
//
//  Reopening a title resumes where it was last saved, even before the screen's
//  model has caught up with the save.
//

import Foundation
@testable import Lume
import Testing

@MainActor
@Suite(.readsGlobalState)
struct RecentResumePointsTests {
    private let episode = PlayableMedia.ContentRef.episode("e1")
    private let then = Date(timeIntervalSince1970: 1_700_000_000)

    init() {
        RecentResumePoints.reset()
    }

    /// The reported sequence: saved at 5:51, reopened from a model still at 0.
    @Test func `a save newer than the model wins`() {
        RecentResumePoints.record(351.3, for: episode, at: then)
        #expect(RecentResumePoints.position(for: episode, stored: 0, storedAt: then.addingTimeInterval(-600)) == 351.3)
        #expect(RecentResumePoints.position(for: episode, stored: 0, storedAt: nil) == 351.3)
    }

    @Test func `progress arriving later, from another device, wins`() {
        RecentResumePoints.record(351.3, for: episode, at: then)
        #expect(RecentResumePoints.position(for: episode, stored: 900, storedAt: then.addingTimeInterval(60)) == 900)
    }

    @Test func `a title never saved here uses the model`() {
        #expect(RecentResumePoints.position(for: episode, stored: 42, storedAt: then) == 42)
    }

    @Test func `live channels are not recorded`() {
        let live = PlayableMedia.ContentRef.live("c1")
        RecentResumePoints.record(120, for: live, at: then)
        #expect(RecentResumePoints.position(for: live, stored: 0, storedAt: nil) == 0)
    }
}

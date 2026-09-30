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

/// The record is process-wide and these run in parallel, so each test works on
/// a title of its own rather than resetting shared state.
@MainActor
struct RecentResumePointsTests {
    private let episode = PlayableMedia.ContentRef.episode(UUID().uuidString)
    private let then = Date(timeIntervalSince1970: 1_700_000_000)

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
        let live = PlayableMedia.ContentRef.live(UUID().uuidString)
        RecentResumePoints.record(120, for: live, at: then)
        #expect(RecentResumePoints.position(for: live, stored: 0, storedAt: nil) == 0)
    }

    // MARK: - Where a title opens

    /// Resuming a finished episode landed in its last seconds, where
    /// auto-advance played the next one: Previous Episode bounced straight back.
    @Test func `a finished title starts over`() {
        let start = RecentResumePoints.start(for: episode, stored: 2580, storedAt: then, isWatched: true, duration: 2600)
        #expect(start == 0)
    }

    @Test func `past the watched line counts as finished, watched or not`() {
        let start = RecentResumePoints.start(for: episode, stored: 2400, storedAt: then, isWatched: false, duration: 2600)
        #expect(start == 0)
    }

    @Test func `a title partway through resumes`() {
        let start = RecentResumePoints.start(for: episode, stored: 1200, storedAt: then, isWatched: false, duration: 2600)
        #expect(start == 1200)
    }

    /// A watched episode being rewatched this run resumes the rewatch.
    @Test func `a rewatch in progress resumes`() {
        RecentResumePoints.record(600, for: episode, at: then)
        let start = RecentResumePoints.start(
            for: episode, stored: 2580, storedAt: then.addingTimeInterval(-600), isWatched: true, duration: 2600
        )
        #expect(start == 600)
    }

    @Test func `without a duration, a watched title starts over unless a rewatch is underway`() {
        #expect(RecentResumePoints.start(for: episode, stored: 2580, storedAt: then, isWatched: true, duration: nil) == 0)
        RecentResumePoints.record(600, for: episode, at: then)
        let rewatch = RecentResumePoints.start(
            for: episode, stored: 2580, storedAt: then.addingTimeInterval(-600), isWatched: true, duration: nil
        )
        #expect(rewatch == 600)
    }
}

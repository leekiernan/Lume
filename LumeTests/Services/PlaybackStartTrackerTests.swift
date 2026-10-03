//
//  PlaybackStartTrackerTests.swift
//  LumeTests
//
//  Pins the one "has this stream started?" rule every playback engine uses to
//  disarm its startup watchdog. A miss here declares a playing stream dead and
//  falls back to another engine; a false positive leaves a dead stream on a
//  spinner with no watchdog to end it.
//

import Foundation
@testable import Lume
import Testing

@Suite("PlaybackStartTracker")
struct PlaybackStartTrackerTests {
    /// Feeds `samples` in order and returns every non-`nil` proof.
    private func feed(_ tracker: inout PlaybackStartTracker, _ samples: [TimeInterval]) -> [PlaybackStartTracker.Proof] {
        samples.compactMap { tracker.notePlayhead($0) }
    }

    // MARK: - Playhead proof

    @Test
    func `half a second of playhead progress starts the stream`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.notePlayhead(10.0) == nil)
        #expect(tracker.notePlayhead(10.2) == nil)
        #expect(tracker.notePlayhead(10.4) == nil)
        #expect(tracker.notePlayhead(10.5) == .playhead)
        #expect(tracker.hasStarted)
    }

    @Test
    func `progress short of the threshold does not start it`() {
        var tracker = PlaybackStartTracker()
        #expect(feed(&tracker, [0, 0.1, 0.2, 0.3, 0.49]).isEmpty)
        #expect(!tracker.hasStarted)
    }

    @Test
    func `a frozen playhead never starts the stream`() {
        var tracker = PlaybackStartTracker()
        #expect(feed(&tracker, Array(repeating: 42, count: 100)).isEmpty)
        #expect(!tracker.hasStarted)
    }

    @Test
    func `the threshold is configurable`() {
        var tracker = PlaybackStartTracker(proofAdvance: 2)
        #expect(feed(&tracker, [0, 0.5, 1, 1.5, 1.9]).isEmpty)
        #expect(tracker.notePlayhead(2) == .playhead)
    }

    @Test
    func `a single sample is never proof on its own`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.notePlayhead(3600) == nil)
        #expect(!tracker.hasStarted)
    }

    @Test
    func `non-finite samples are ignored`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.notePlayhead(.nan) == nil)
        #expect(tracker.notePlayhead(.infinity) == nil)
        #expect(tracker.notePlayhead(0) == nil)
        #expect(tracker.notePlayhead(.nan) == nil)
        #expect(tracker.notePlayhead(0.5) == .playhead)
    }

    // MARK: - Re-basing

    @Test
    func `a stale higher sample from the replaced stream re-bases down`() {
        // The old catch-up segment reported 300 s; the new one starts near 0.
        var tracker = PlaybackStartTracker()
        #expect(tracker.notePlayhead(300) == nil)
        #expect(tracker.notePlayhead(0) == nil)
        #expect(tracker.notePlayhead(0.3) == nil)
        #expect(tracker.notePlayhead(0.5) == .playhead)
    }

    @Test
    func `each lower sample moves the baseline down`() {
        // Progress is measured from the lowest sample seen, so a run of
        // falling stale samples never adds up to proof.
        var tracker = PlaybackStartTracker()
        #expect(feed(&tracker, [300, 0.25, 0.125, 0.5]).isEmpty)
        #expect(tracker.notePlayhead(0.625) == .playhead)
    }

    @Test
    func `a forward jump is a seek, not progress`() {
        // A stale sample from before a resume seek, then the resumed position.
        var tracker = PlaybackStartTracker()
        #expect(tracker.notePlayhead(1) == nil)
        #expect(tracker.notePlayhead(1200) == nil)
        #expect(!tracker.hasStarted)
        #expect(tracker.notePlayhead(1200.3) == nil)
        #expect(tracker.notePlayhead(1200.5) == .playhead)
    }

    @Test
    func `the largest continuous step still counts as progress`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.notePlayhead(0) == nil)
        #expect(tracker.notePlayhead(PlaybackStartTracker.maxSampleStep) == .playhead)
    }

    @Test
    func `discarding samples re-bases on the next one`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.notePlayhead(0) == nil)
        #expect(tracker.notePlayhead(0.4) == nil)
        tracker.discardSamples()
        #expect(tracker.notePlayhead(2) == nil)
        #expect(tracker.notePlayhead(2.4) == nil)
        #expect(tracker.notePlayhead(2.5) == .playhead)
    }

    // MARK: - Fires once

    @Test
    func `the playhead proof fires exactly once`() {
        var tracker = PlaybackStartTracker()
        let proofs = feed(&tracker, Array(stride(from: 0, through: 10, by: 0.1)))
        #expect(proofs == [.playhead])
    }

    @Test
    func `the engine signal fires exactly once`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.noteEngineStarted() == .engine)
        #expect(tracker.noteEngineStarted() == nil)
        #expect(tracker.noteEngineStarted() == nil)
    }

    @Test
    func `whichever proof comes first wins and the other stays quiet`() {
        var engineFirst = PlaybackStartTracker()
        #expect(engineFirst.noteEngineStarted() == .engine)
        #expect(feed(&engineFirst, [0, 0.5, 1, 1.5]).isEmpty)

        var playheadFirst = PlaybackStartTracker()
        #expect(feed(&playheadFirst, [0, 0.5]) == [.playhead])
        #expect(playheadFirst.noteEngineStarted() == nil)
    }

    // MARK: - Engine signal

    @Test
    func `an ungated engine signal starts the stream straight away`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.noteEngineStarted() == .engine)
        #expect(tracker.hasStarted)
    }

    @Test
    func `a ready-gated signal waits for this stream's ready`() {
        // KSPlayer: a stale `.bufferFinished` from the previous session lands
        // before the new session's `.readyToPlay`.
        var tracker = PlaybackStartTracker()
        #expect(tracker.noteEngineStarted(requiringReady: true) == nil)
        #expect(!tracker.hasStarted)
        tracker.noteEngineReady()
        #expect(tracker.isEngineReady)
        #expect(tracker.noteEngineStarted(requiringReady: true) == .engine)
    }

    @Test
    func `the playhead proof needs no ready gate`() {
        // KSPlayer: the new stream's `.readyToPlay` was consumed before the
        // swap reset, so only the playhead can prove it.
        var tracker = PlaybackStartTracker()
        #expect(!tracker.isEngineReady)
        #expect(feed(&tracker, [0, 0.2, 0.5]) == [.playhead])
    }

    // MARK: - Stream boundaries

    @Test func `displayed frames prove startup despite jumping then frozen HLS time`() {
        var tracker = PlaybackStartTracker()
        #expect(feed(&tracker, [1071.4, 32.1, 59.5, 59.5]).isEmpty)
        #expect(tracker.noteDisplayedFrames(86) == nil)
        #expect(tracker.noteDisplayedFrames(178) == .displayedFrames)
        #expect(tracker.hasStarted)
        #expect(tracker.noteDisplayedFrames(285) == nil)
        #expect(tracker.noteEngineStarted() == nil)
    }

    @Test func `a frozen frame count leaves startup detection armed`() {
        var tracker = PlaybackStartTracker()
        for count in [UInt64(0), 86] {
            // Reset for each frozen run, including an initially nonzero counter.
            tracker.beginStream()
            #expect(tracker.noteDisplayedFrames(count) == nil)
            #expect(tracker.noteDisplayedFrames(count) == nil)
            #expect(!tracker.hasStarted)
        }
    }

    @Test func `frame counters rebase at stream and reconnect boundaries`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.noteDisplayedFrames(100) == nil)
        tracker.beginStream()
        #expect(tracker.noteDisplayedFrames(101) == nil)
        tracker.beginReconnect()
        #expect(tracker.noteDisplayedFrames(102) == nil)
        #expect(!tracker.hasStarted)
        #expect(tracker.noteDisplayedFrames(103) == .displayedFrames)
    }

    @Test func `a decreasing or wrapped frame counter does not prove startup`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.noteDisplayedFrames(UInt64.max) == nil)
        #expect(tracker.noteDisplayedFrames(0) == nil)
        #expect(!tracker.hasStarted)
        #expect(tracker.noteDisplayedFrames(1) == .displayedFrames)
    }

    @Test
    func `a new stream starts from scratch`() {
        var tracker = PlaybackStartTracker()
        tracker.noteEngineReady()
        #expect(feed(&tracker, [0, 0.5]) == [.playhead])

        tracker.beginStream()
        #expect(!tracker.hasStarted)
        #expect(!tracker.isEngineReady)
        // The old stream's baseline is gone: 0.75 is the new stream's first sample.
        #expect(tracker.notePlayhead(0.75) == nil)
        #expect(tracker.noteEngineStarted(requiringReady: true) == nil)
        #expect(tracker.notePlayhead(1.25) == .playhead)
    }

    @Test
    func `each stream reports its own start once`() {
        var tracker = PlaybackStartTracker()
        var proofs: [PlaybackStartTracker.Proof] = []
        for _ in 0 ..< 3 {
            tracker.beginStream()
            proofs += feed(&tracker, [0, 0.3, 0.6, 0.9])
            if let proof = tracker.noteEngineStarted() { proofs.append(proof) }
        }
        #expect(proofs == [.playhead, .playhead, .playhead])
    }

    @Test
    func `a reconnect keeps the start but drops the ready gate and baseline`() {
        var tracker = PlaybackStartTracker()
        tracker.noteEngineReady()
        #expect(tracker.noteEngineStarted(requiringReady: true) == .engine)
        #expect(tracker.notePlayhead(100) == nil)

        tracker.beginReconnect()
        #expect(tracker.hasStarted)
        #expect(!tracker.isEngineReady)
        // Already started, so nothing on the reconnected stream reports again.
        #expect(feed(&tracker, [100, 100.5, 101]).isEmpty)
        tracker.noteEngineReady()
        #expect(tracker.noteEngineStarted(requiringReady: true) == nil)
    }

    @Test
    func `a reconnect before the first frame still needs fresh proof`() {
        var tracker = PlaybackStartTracker()
        #expect(tracker.notePlayhead(0) == nil)
        #expect(tracker.notePlayhead(0.4) == nil)
        tracker.beginReconnect()
        // 0.4 → 0.6 would have crossed 0.5 on the old baseline; not on the new one.
        #expect(tracker.notePlayhead(0.4) == nil)
        #expect(tracker.notePlayhead(0.6) == nil)
        #expect(tracker.notePlayhead(1.0) == .playhead)
    }
}

//
//  PlaybackQoETests.swift
//  LumeTests
//
//  Correctness of the QoE accounting — the counters that answer "how slow is
//  startup for real users". Each test uses its own `UserDefaults` suite so these
//  never race the singleton (or each other) through `UserDefaults.standard`.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct PlaybackQoETests {
    /// The engine instance that owns the sessions these tests open.
    private let engineInstance = NSObject()

    /// A tracker backed by a throwaway suite.
    private func makeTracker() -> (qoe: PlaybackQoE, suiteName: String) {
        let suiteName = "PlaybackQoETests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (PlaybackQoE(defaults: defaults), suiteName)
    }

    private func tearDown(_ suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test
    func `a completed startup records one session and one join time`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }

        qoe.beginStartup(engine: .ksPlayer, isLive: true, owner: engineInstance)
        qoe.noteFirstFrame()

        let stats = qoe.summary.engines[PlayerEngineKind.ksPlayer.rawValue]
        #expect(stats?.sessions == 1)
        #expect(stats?.firstFrames == 1)
        #expect((stats?.lastJoinTime ?? -1) >= 0)
        #expect(stats?.exitsBeforeVideoStart == 0)
    }

    @Test
    func `join time is recorded once even if the engine reports the first frame twice`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }

        qoe.beginStartup(engine: .avPlayer, isLive: false, owner: engineInstance)
        qoe.noteFirstFrame()
        qoe.noteFirstFrame()
        qoe.noteFirstFrame()

        #expect(qoe.summary.engines[PlayerEngineKind.avPlayer.rawValue]?.firstFrames == 1)
    }

    @Test
    func `abandoning a stream before the first frame counts as an exit before video start`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }

        qoe.beginStartup(engine: .vlcKit, isLive: true, owner: engineInstance)
        qoe.endSession(owner: engineInstance)

        let stats = qoe.summary.engines[PlayerEngineKind.vlcKit.rawValue]
        #expect(stats?.exitsBeforeVideoStart == 1)
        #expect(stats?.firstFrames == 0)
        #expect(stats?.watchedSeconds == 0)
    }

    @Test
    func `stalls before the first frame are join time, not rebuffering`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }

        qoe.beginStartup(engine: .ksPlayer, isLive: true, owner: engineInstance)
        // Startup buffering — the spinner before any frame arrives.
        qoe.noteStallBegan()
        qoe.noteStallEnded()
        qoe.noteFirstFrame()

        #expect(qoe.summary.engines[PlayerEngineKind.ksPlayer.rawValue]?.rebuffers == 0)
    }

    @Test
    func `a mid-stream stall is counted once it clears`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }

        qoe.beginStartup(engine: .ksPlayer, isLive: true, owner: engineInstance)
        qoe.noteFirstFrame()
        qoe.noteStallBegan()
        // A repeated "still stalled" signal must not double-count.
        qoe.noteStallBegan()
        qoe.noteStallEnded()

        let stats = qoe.summary.engines[PlayerEngineKind.ksPlayer.rawValue]
        #expect(stats?.rebuffers == 1)
        #expect((stats?.rebufferSeconds ?? -1) >= 0)
    }

    @Test
    func `a cleared stall is persisted at the session boundary, not mid-playback`() throws {
        let suiteName = "PlaybackQoETests-\(UUID().uuidString)"
        defer { tearDown(suiteName) }
        let defaults = try #require(UserDefaults(suiteName: suiteName))

        let qoe = PlaybackQoE(defaults: defaults)
        qoe.beginStartup(engine: .ksPlayer, isLive: true, owner: engineInstance)
        qoe.noteFirstFrame()
        qoe.noteStallBegan()
        qoe.noteStallEnded()

        let midPlayback = PlaybackQoE(defaults: defaults)
        #expect(midPlayback.summary.engines[PlayerEngineKind.ksPlayer.rawValue]?.rebuffers == 0)

        qoe.endSession(owner: engineInstance)
        let afterSession = PlaybackQoE(defaults: defaults)
        #expect(afterSession.summary.engines[PlayerEngineKind.ksPlayer.rawValue]?.rebuffers == 1)
    }

    @Test
    func `an unclosed stall is still accounted for when the session ends`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }

        qoe.beginStartup(engine: .lumeEngine, isLive: true, owner: engineInstance)
        qoe.noteFirstFrame()
        qoe.noteStallBegan()
        qoe.endSession(owner: engineInstance)

        #expect(qoe.summary.engines[PlayerEngineKind.lumeEngine.rawValue]?.rebuffers == 1)
    }

    @Test
    func `restarting startup without ending the session closes the previous one`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }

        // A live-channel zap: the engine begins a new attempt without a teardown.
        qoe.beginStartup(engine: .ksPlayer, isLive: true, owner: engineInstance)
        qoe.noteFirstFrame()
        qoe.beginStartup(engine: .ksPlayer, isLive: true, owner: engineInstance)
        qoe.noteFirstFrame()

        let stats = qoe.summary.engines[PlayerEngineKind.ksPlayer.rawValue]
        #expect(stats?.sessions == 2)
        #expect(stats?.firstFrames == 2)
    }

    @Test
    func `startup failures and engine fallbacks are counted separately`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }

        qoe.beginStartup(engine: .ksPlayer, isLive: true, owner: engineInstance)
        qoe.noteStartupFailure()
        qoe.noteEngineFallback(to: .vlcKit)

        #expect(qoe.summary.engines[PlayerEngineKind.ksPlayer.rawValue]?.startupFailures == 1)
        #expect(qoe.summary.engineFallbacks == 1)
    }

    @Test
    func `counters survive a restart through the persisted summary`() throws {
        let suiteName = "PlaybackQoETests-\(UUID().uuidString)"
        defer { tearDown(suiteName) }
        let defaults = try #require(UserDefaults(suiteName: suiteName))

        let first = PlaybackQoE(defaults: defaults)
        first.beginStartup(engine: .ksPlayer, isLive: false, owner: engineInstance)
        first.noteFirstFrame()

        let second = PlaybackQoE(defaults: defaults)
        #expect(second.summary.engines[PlayerEngineKind.ksPlayer.rawValue]?.firstFrames == 1)
    }

    @Test
    func `rebuffer ratio is nil until something has been watched`() {
        var stats = EngineQoEStats()
        #expect(stats.rebufferRatio == nil)

        stats.watchedSeconds = 100
        stats.rebufferSeconds = 5
        #expect(stats.rebufferRatio == 0.05)
    }

    @Test
    func `reset clears every counter`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }

        qoe.beginStartup(engine: .ksPlayer, isLive: true, owner: engineInstance)
        qoe.noteFirstFrame()
        qoe.reset()

        #expect(qoe.summary.engines.isEmpty)
        #expect(qoe.summary.totalSessions == 0)
    }

    /// A fallback or rebuild overlaps two engine views: the next one opens its
    /// session before the last one's teardown runs. That teardown must not
    /// close the new session.
    @Test
    func `a replaced engine's teardown doesn't close its replacement's session`() {
        let (qoe, suite) = makeTracker()
        defer { tearDown(suite) }
        let failing = NSObject()
        let replacement = NSObject()

        qoe.beginStartup(engine: .ksPlayer, isLive: true, owner: failing)
        qoe.beginStartup(engine: .vlcKit, isLive: true, owner: replacement)
        qoe.endSession(owner: failing)
        qoe.noteFirstFrame()

        let vlc = qoe.summary.engines[PlayerEngineKind.vlcKit.rawValue]
        #expect(vlc?.firstFrames == 1)
        #expect(vlc?.exitsBeforeVideoStart ?? 0 == 0)
    }
}

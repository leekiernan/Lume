import Foundation
@testable import Lume
import Testing

struct PlaybackActivityFreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `long titles and missing windows use the short lease`() {
        let deadline = now.addingTimeInterval(45)
        #expect(PlaybackActivityFreshness.deadline(now: now, windowEnd: now.addingTimeInterval(3600)) == deadline)
        #expect(PlaybackActivityFreshness.deadline(now: now, windowEnd: nil) == deadline)
    }

    @Test func `ending and expired windows invalidate the lease sooner`() {
        for offset in [-5.0, 0, 10] {
            let end = now.addingTimeInterval(offset)
            #expect(PlaybackActivityFreshness.deadline(now: now, windowEnd: end) == end)
        }
    }

    @Test func `steady playback renews without any seek pause or duration change`() {
        #expect(PlaybackActivityFreshness.needsRenewal(lastUpdate: nil, now: now))
        #expect(!PlaybackActivityFreshness.needsRenewal(lastUpdate: now, now: now.addingTimeInterval(14)))
        #expect(PlaybackActivityFreshness.needsRenewal(lastUpdate: now, now: now.addingTimeInterval(15)))
        #expect(PlaybackActivityFreshness.needsRenewal(lastUpdate: now, now: now.addingTimeInterval(-1)))
    }

    @Test func `updates renew freshness but missing updates expire every playback status`() {
        let deadline = PlaybackActivityFreshness.deadline(now: now, windowEnd: nil)
        for status: PlaybackActivityStatus in [.loading, .playing, .paused, .buffering, .unavailable] {
            #expect(PlaybackActivityFreshness.presentation(status: status, isStale: false, freshUntil: deadline, now: now) == status)
            let stale = PlaybackActivityFreshness.presentation(status: status, isStale: false, freshUntil: deadline, now: deadline)
            #expect(stale == .unavailable)
            #expect(!stale.advancesProgress)
        }
        let renewed = PlaybackActivityFreshness.deadline(now: now.addingTimeInterval(15), windowEnd: nil)
        #expect(PlaybackActivityFreshness.presentation(status: .playing, isStale: false, freshUntil: renewed, now: deadline) == .playing)
    }

    @Test func `system staleness overrides a playing snapshot even without a deadline`() {
        #expect(PlaybackActivityFreshness.presentation(status: .playing, isStale: true, freshUntil: nil, now: now) == .unavailable)
    }

    @MainActor
    @Test func `remote commands cannot animate a stream that never started or failed`() {
        #expect(NowPlayingService.activityStatus(for: .starting(.open), isPaused: false) == .loading)
        #expect(NowPlayingService.activityStatus(for: .failed(.startup), isPaused: false) == .unavailable)
        #expect(NowPlayingService.activityStatus(for: .playing, isPaused: true) == .paused)
        #expect(NowPlayingService.activityStatus(for: .paused, isPaused: false) == .playing)
    }

    @MainActor
    @Test func `session state alone confirms playback and only confirmed playback animates`() {
        let states: [(PlaybackSessionMachine.State, PlaybackActivityStatus)] = [
            (.idle, .loading), (.resolving, .loading),
            (.starting(.open), .loading), (.starting(.fallback), .loading), (.starting(.swap), .loading),
            (.playing, .playing), (.paused, .paused), (.rebuffering, .buffering),
            (.failed(.startup), .unavailable), (.failed(.playback), .unavailable), (.closed, .unavailable)
        ]
        for (state, expected) in states {
            let status = NowPlayingService.activityStatus(for: state)
            #expect(status == expected)
            #expect(status.advancesProgress == (expected == .playing))
        }
    }
}

#if os(iOS)
    import Foundation
    @testable import Lume
    import Testing

    struct PlaybackActivityStaleDateTests {
        private let now = Date(timeIntervalSince1970: 1_800_000_000)

        private func state(isLive: Bool, isPaused: Bool, end: Date?) -> PlaybackActivityAttributes.ContentState {
            var state = PlaybackActivityAttributes.ContentState(
                title: "Title", subtitle: nil, isLive: isLive, isPaused: isPaused
            )
            state.windowStart = now.addingTimeInterval(-600)
            state.windowEnd = end
            return state
        }

        @Test func `live goes stale at the programme boundary`() {
            let end = now.addingTimeInterval(900)
            #expect(PlaybackActivityController.staleDate(for: state(isLive: true, isPaused: false, end: end), now: now) == end)
        }

        /// The bar is a self-running timer: past the title's projected end it
        /// only describes a session that stopped reporting.
        @Test func `playing VOD goes stale at its projected end`() {
            let end = now.addingTimeInterval(3600)
            #expect(PlaybackActivityController.staleDate(for: state(isLive: false, isPaused: false, end: end), now: now) == end)
        }

        @Test func `paused VOD stays fresh through a long pause`() {
            let end = now.addingTimeInterval(3600)
            let stale = PlaybackActivityController.staleDate(for: state(isLive: false, isPaused: true, end: end), now: now)
            #expect(stale == now.addingTimeInterval(4 * 60 * 60))
        }

        @Test func `VOD without a window falls back to the long lifetime`() {
            let stale = PlaybackActivityController.staleDate(for: state(isLive: false, isPaused: false, end: nil), now: now)
            #expect(stale == now.addingTimeInterval(4 * 60 * 60))
        }
    }
#endif

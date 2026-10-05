#if os(iOS)
    import Foundation
    @testable import Lume
    import Testing

    @MainActor
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
            let end = now.addingTimeInterval(10)
            #expect(PlaybackActivityController.staleDate(for: state(isLive: true, isPaused: false, end: end), now: now) == end)
        }

        /// A title-length lease would keep claiming playback after force-close.
        @Test func `playing VOD cannot run unconfirmed to its projected end`() {
            let end = now.addingTimeInterval(3600)
            #expect(PlaybackActivityController.staleDate(for: state(isLive: false, isPaused: false, end: end), now: now) == now.addingTimeInterval(45))
        }

        @Test func `paused VOD also needs the short lease`() {
            let end = now.addingTimeInterval(3600)
            let stale = PlaybackActivityController.staleDate(for: state(isLive: false, isPaused: true, end: end), now: now)
            #expect(stale == now.addingTimeInterval(45))
        }

        @Test func `VOD without a window also expires`() {
            let stale = PlaybackActivityController.staleDate(for: state(isLive: false, isPaused: false, end: nil), now: now)
            #expect(stale == now.addingTimeInterval(45))
        }

        @Test func `older activity content decodes without status or freshness`() throws {
            let data = Data(#"{"title":"Title","isLive":false,"isPaused":true}"#.utf8)
            let value = try JSONDecoder().decode(PlaybackActivityAttributes.ContentState.self, from: data)
            #expect(value.presentation(isStale: false, now: now) == .paused)
            #expect(value.presentation(isStale: true, now: now) == .unavailable)
        }
    }
#endif

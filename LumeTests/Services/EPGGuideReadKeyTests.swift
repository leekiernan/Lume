import Foundation
@testable import Lume
import Testing

struct EPGGuideReadKeyTests {
    @Test func `same sized channel sets foreground returns and hour changes invalidate the guide`() {
        let scope = ChannelEPGLoadMachine.Scope(playlistPrefix: "playlist-", visibilityToken: "profile", channelScope: .favorites)
        let original = EPGGuideReadKey(scope: scope, channelIDs: ["a"], revision: 1, hour: 1)
        #expect(original != EPGGuideReadKey(scope: scope, channelIDs: ["b"], revision: 1, hour: 1))
        #expect(original != EPGGuideReadKey(scope: scope, channelIDs: ["a"], revision: 2, hour: 1))
        #expect(original != EPGGuideReadKey(scope: scope, channelIDs: ["a"], revision: 1, hour: 2))
        let ordered = EPGGuideReadKey(scope: scope, channelIDs: ["a", "b"], channelOrder: ["a", "b"], revision: 1, hour: 1)
        #expect(ordered != EPGGuideReadKey(scope: scope, channelIDs: ["a", "b"], channelOrder: ["b", "a"], revision: 1, hour: 1))
    }

    @Test func `a long lived guide reanchors without shifting at every minute tick`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timeline = EPGTimeline.live(now: now, pointsPerMinute: 10)
        #expect(!timeline.needsReanchor(at: now.addingTimeInterval(60)))
        #expect(timeline.needsReanchor(at: now.addingTimeInterval(24 * 3600)))
        #expect(timeline.needsReanchor(at: timeline.start.addingTimeInterval(-60)))
    }
}

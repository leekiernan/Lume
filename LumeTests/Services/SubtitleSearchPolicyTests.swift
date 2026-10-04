@testable import Lume
import Testing

struct SubtitleSearchPolicyTests {
    @Test func `search requires on-demand media configured API and engine sidecar support`() {
        for live in [false, true] {
            for configured in [false, true] {
                for supported in [false, true] {
                    #expect(SubtitleSearchPolicy.canSearch(
                        isLive: live, isConfigured: configured, supportsExternalSubtitles: supported
                    ) == (!live && configured && supported))
                }
            }
        }
    }
}

import Foundation
@testable import Lume
import SwiftUI
import Testing

struct SubtitleSearchPolicyTests {
    @MainActor
    @Test(.readsGlobalState) func `AVPlayer exposes no subtitle search presentation action`() throws {
        let player = AVPlayerCoordinator()
        let media = try PlayableMedia(id: "movie", url: #require(URL(string: "https://media.test/movie.mp4")), title: "Movie", subtitle: nil, posterURL: nil, kind: .vod, startTime: 0, contentRef: .movie("movie"))
        #expect(!player.supportsExternalSubtitles)
        #expect(player.subtitleSearchAction(for: media, isPresented: .constant(false)) == nil)
    }

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

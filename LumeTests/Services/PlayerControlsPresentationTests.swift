@testable import Lume
import Testing

@MainActor
struct PlayerControlsPresentationTests {
    @Test(arguments: PlayerEngineKind.allCases)
    func `shared track menus retain empty single and multiple track gates`(engine: PlayerEngineKind) {
        for count in 0 ... 2 {
            let tracks = (0 ..< count).map { PlayerTrackOption(id: String($0), label: "Track", isSelected: $0 == 0) }
            let presentation = PlayerControlsPresentation(
                engine: engine, isPlaying: true, videoInfo: nil,
                audioTracks: tracks, textTracks: tracks, rate: 1,
                isPipSupported: false, isPipActive: false
            )
            #expect(presentation.showsAudioMenu == (count > 1))
            #expect(presentation.showsSubtitleMenu(searchAvailable: false) == (count > 0))
            #expect(presentation.showsSubtitleMenu(searchAvailable: true))
            #expect(presentation.isAspectFill == nil)
        }
    }
}

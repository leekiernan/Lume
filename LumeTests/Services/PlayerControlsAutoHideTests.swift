@testable import Lume
import Testing

struct PlayerControlsAutoHideTests {
    @Test(arguments: [false, true], [false, true])
    func `only playing with no panel or accessibility suppression may hide`(playing: Bool, panel: Bool) {
        for suppressed in [false, true] {
            let allowed = PlayerControlsAutoHide.mayHide(isPlaying: playing, isPanelOpen: panel, isSuppressed: suppressed)
            #expect(allowed == (playing && !panel && !suppressed))
        }
    }

    @Test func `eligibility must be rechecked after a delayed hide was scheduled`() {
        #expect(PlayerControlsAutoHide.mayHide(isPlaying: true, isPanelOpen: false, isSuppressed: false))
        #expect(!PlayerControlsAutoHide.mayHide(isPlaying: false, isPanelOpen: false, isSuppressed: false))
        #expect(!PlayerControlsAutoHide.mayHide(isPlaying: true, isPanelOpen: true, isSuppressed: false))
        #expect(!PlayerControlsAutoHide.mayHide(isPlaying: true, isPanelOpen: false, isSuppressed: true))
    }
}

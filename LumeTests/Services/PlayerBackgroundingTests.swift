@testable import Lume
import SwiftUI
import Testing

struct PlayerBackgroundingTests {
    @Test func `a stream carried by PiP is never paused`() {
        for phase in [ScenePhase.active, .inactive, .background] {
            #expect(!PlayerBackgrounding.shouldPause(for: phase, pipActive: true))
        }
    }

    @Test func `leaving the foreground pauses on this platform's trigger`() {
        #expect(!PlayerBackgrounding.shouldPause(for: .active))
        #expect(PlayerBackgrounding.shouldPause(for: .background))
        #if os(iOS)
            // `.inactive` precedes automatic PiP (and fires for Control Center).
            #expect(!PlayerBackgrounding.shouldPause(for: .inactive))
        #else
            #expect(PlayerBackgrounding.shouldPause(for: .inactive))
        #endif
    }
}

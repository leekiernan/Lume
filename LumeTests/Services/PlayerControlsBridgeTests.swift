@testable import Lume
import Testing

@MainActor
struct PlayerControlsBridgeTests {
    @Test func `absent or declining host claims fall through exactly once`() {
        var toggles = 0
        PlayerControlsBridge.performPlayPause(using: nil) { toggles += 1 }
        #expect(toggles == 1)
        let bridge = PlayerControlsBridge()
        PlayerControlsBridge.performPlayPause(using: bridge) { toggles += 1 }
        #expect(toggles == 2)
        var claims = 0
        bridge.playPauseClaim = { claims += 1; return false }
        PlayerControlsBridge.performPlayPause(using: bridge) { toggles += 1 }
        #expect(claims == 1 && toggles == 3)
    }

    @Test func `a current overlay owns the press without toggling the engine`() {
        let bridge = PlayerControlsBridge()
        var claims = 0
        var toggles = 0
        bridge.playPauseClaim = { claims += 1; return true }
        PlayerControlsBridge.performPlayPause(using: bridge) { toggles += 1 }
        #expect(claims == 1 && toggles == 0)
        bridge.playPauseClaim = nil
        PlayerControlsBridge.performPlayPause(using: bridge) { toggles += 1 }
        #expect(claims == 1 && toggles == 1)
        bridge.playPauseClaim = { claims += 1; return true }
        PlayerControlsBridge.performPlayPause(using: bridge) { toggles += 1 }
        #expect(claims == 2 && toggles == 1)
    }

    @Test func `play pause dispatch never consults or clears the independently owned back claim`() {
        let bridge = PlayerControlsBridge()
        var backs = 0
        bridge.backClaim = { backs += 1; return true }
        PlayerControlsBridge.performPlayPause(using: bridge) {}
        #expect(backs == 0)
        #expect(bridge.claimsBack())
        #expect(backs == 1)
    }
}

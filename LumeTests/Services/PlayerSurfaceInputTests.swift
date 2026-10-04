@testable import Lume
import Testing

nonisolated struct PlayerSurfaceInputTests {
    @Test(arguments: [false, true], [false, true])
    func `catcher yields to drawn controls browser and terminal failure`(drawn: Bool, browser: Bool) {
        for failed in [false, true] {
            #expect(PlayerSurfaceInput.catcherDisabled(controlsDrawn: drawn, browserOpen: browser, failed: failed) == (drawn || browser || failed))
        }
    }

    @Test func `startup keeps the bare picture available until controls actually draw`() {
        #expect(!PlayerSurfaceInput.catcherDisabled(controlsDrawn: false, browserOpen: false, failed: false))
    }

    @Test func `only live streams browse and surf with the remote`() {
        let directions: [PlayerSurfaceInput.Direction] = [.left, .right, .upward, .downward, .other]
        for direction in directions {
            #expect(PlayerSurfaceInput.action(for: direction, isLive: false) == .controls)
        }
        #expect(PlayerSurfaceInput.action(for: .left, isLive: true) == .browser)
        for direction in [PlayerSurfaceInput.Direction.right, .upward, .downward] {
            #expect(PlayerSurfaceInput.action(for: direction, isLive: true) == .surf)
        }
        #expect(PlayerSurfaceInput.action(for: .other, isLive: true) == .controls)
    }
}

/// Input policy for the bare picture. Focus ownership and media changes are
/// still native-view/host responsibilities, never playback-machine transitions.
nonisolated enum PlayerSurfaceInput {
    enum Direction { case left, right, upward, downward, other }
    enum Action { case controls, browser, surf }

    static func action(for direction: Direction, isLive: Bool) -> Action {
        guard isLive else { return .controls }
        switch direction {
        case .left: return .browser
        case .right, .upward, .downward: return .surf
        case .other: return .controls
        }
    }

    static func catcherDisabled(controlsDrawn: Bool, browserOpen: Bool, failed: Bool) -> Bool {
        controlsDrawn || browserOpen || failed
    }
}

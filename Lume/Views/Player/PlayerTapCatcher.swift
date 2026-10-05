import SwiftUI

/// Full-picture input surface, below controls/error/episode overlays. Keep
/// the focus binding in the host so episode-button handoff stays unchanged.
struct PlayerTapCatcher: View {
    #if os(tvOS)
        let isLive: Bool
        let controlsDrawn: Bool
        let browserOpen: Bool
        let failed: Bool
        let focused: FocusState<Bool>.Binding
        let showControls: () -> Void
        let openBrowser: () -> Void
        let surf: (MoveCommandDirection) -> Void

        var body: some View {
            Button(action: showControls) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(PlayerInvisibleButtonStyle())
            // During startup requested chrome may not yet be drawn: keep the
            // catcher available for a second channel surf while it opens.
            .disabled(PlayerSurfaceInput.catcherDisabled(controlsDrawn: controlsDrawn, browserOpen: browserOpen, failed: failed))
            .focused(focused)
            .tvRemoteMoveCommand { direction in
                let input: PlayerSurfaceInput.Direction = switch direction {
                case .left: .left
                case .right: .right
                case .up: .upward
                case .down: .downward
                @unknown default: .other
                }
                switch PlayerSurfaceInput.action(for: input, isLive: isLive) {
                case .controls: showControls()
                case .browser: openBrowser()
                case .surf: surf(direction)
                }
            }
        }
    #else
        let toggleControls: () -> Void

        var body: some View {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleControls)
        }
    #endif
}

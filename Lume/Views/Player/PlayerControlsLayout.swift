//
//  PlayerControlsLayout.swift
//  Lume
//
//  How much of the bottom of the player the engine's controls take up, so the
//  episode overlays (`PlayerEpisodeOverlays`) can sit above them rather than
//  hide behind them. Each engine draws its own controls, so each reports its
//  bottom block with `reportsControlsHeight()`; the host puts one of these in
//  the environment for the player it builds.
//

import SwiftUI

@MainActor
@Observable
final class PlayerControlsLayout {
    /// The height of the controls' bottom block, including its bottom padding.
    /// Only meaningful while the controls show.
    var height: CGFloat = 0
}

extension View {
    /// Reports this view's height as the controls' bottom block. A no-op
    /// without a host layout (Multi-View tiles).
    func reportsControlsHeight() -> some View {
        modifier(ControlsHeightReporter())
    }
}

private struct ControlsHeightReporter: ViewModifier {
    @Environment(PlayerControlsLayout.self) private var layout: PlayerControlsLayout?

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            layout?.height = height
        }
    }
}

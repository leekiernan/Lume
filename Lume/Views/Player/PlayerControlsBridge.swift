//
//  PlayerControlsBridge.swift
//  Lume
//
//  What the engine's controls and the episode buttons (`PlayerEpisodeOverlays`)
//  need from each other. The host puts one in the environment for the player
//  it builds; each engine draws its own controls and owns the remote, so both
//  sides meet here rather than through four engine-specific paths.
//
//  - Layout: each engine's controls report their bottom block
//    (`reportsControlsHeight()`), and the buttons rise above it.
//  - tvOS focus: with the controls hidden, an episode button holds the remote
//    rather than the engine's invisible tap-catcher, and a direction pressed
//    on it raises the controls just as the catcher would
//    (`episodeButtonFocusHandoff`).
//

import SwiftUI

@MainActor
@Observable
final class PlayerControlsBridge {
    /// The height of the controls' bottom block, including its bottom padding.
    /// Only meaningful while the controls show.
    var height: CGFloat = 0
    /// Whether an episode button (Skip Intro, Next Episode) is on screen. With
    /// the controls hidden it takes the remote's focus itself, so the engine
    /// leaves its tap-catcher alone.
    var episodeButtonShowing = false
    /// Bumped when an episode button holding focus over a bare picture hears a
    /// direction: the viewer wants the controls, as they would from the catcher.
    private(set) var controlsRequests = 0

    func requestControls() {
        controlsRequests += 1
    }
}

extension View {
    /// Reports this view's height as the controls' bottom block. A no-op
    /// without a host bridge (Multi-View tiles).
    func reportsControlsHeight() -> some View {
        modifier(ControlsHeightReporter())
    }
}

private struct ControlsHeightReporter: ViewModifier {
    @Environment(PlayerControlsBridge.self) private var bridge: PlayerControlsBridge?

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            bridge?.height = height
        }
    }
}

#if os(tvOS)
    extension View {
        /// The engine's half of the remote handoff: when the controls hide, or
        /// an episode button goes away with them hidden, focus returns to the
        /// tap-catcher — unless an episode button is showing, which takes it
        /// itself. A direction pressed on that button raises the controls.
        func episodeButtonFocusHandoff(
            controlsVisible: Bool,
            catcherFocused: FocusState<Bool>.Binding,
            showControls: @escaping () -> Void
        ) -> some View {
            modifier(EpisodeButtonFocusHandoff(
                controlsVisible: controlsVisible,
                catcherFocused: catcherFocused,
                showControls: showControls
            ))
        }
    }

    private struct EpisodeButtonFocusHandoff: ViewModifier {
        let controlsVisible: Bool
        let catcherFocused: FocusState<Bool>.Binding
        let showControls: () -> Void

        @Environment(PlayerControlsBridge.self) private var bridge: PlayerControlsBridge?

        func body(content: Content) -> some View {
            content
                .onChange(of: controlsVisible) { _, _ in focusCatcherIfFree() }
                .onChange(of: bridge?.episodeButtonShowing) { _, _ in focusCatcherIfFree() }
                .onChange(of: bridge?.controlsRequests) { _, _ in showControls() }
        }

        /// Hands focus to the tap-catcher over a bare picture, so the remote
        /// can bring the controls back.
        private func focusCatcherIfFree() {
            guard !controlsVisible, bridge?.episodeButtonShowing != true else { return }
            Task { @MainActor in catcherFocused.wrappedValue = true }
        }
    }
#endif

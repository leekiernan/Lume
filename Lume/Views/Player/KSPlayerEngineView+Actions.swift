//
//  KSPlayerEngineView+Actions.swift
//  Lume
//
//  The transport actions every platform's KSPlayer chrome drives — play/pause,
//  the controls auto-hide timer, the lock-screen transport handoff and closing
//  the player. Kept out of the main file, which is at its length cap.
//

import KSPlayer
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

extension KSPlayerEngineView {
    /// Hands the session's remote-command transport to `NowPlayingService`.
    /// KSPlayer's own remote-command registration is disabled (see
    /// `makeOptions`), so this is the only handler set.
    func attachNowPlayingTransport() {
        NowPlayingService.shared.attachTransport(.init(
            isPlaying: { [weak coordinator] in coordinator?.playerLayer?.state.isPlaying ?? false },
            play: { [weak coordinator] in coordinator?.playerLayer?.play() },
            pause: { [weak coordinator] in coordinator?.playerLayer?.pause() },
            seek: { [weak coordinator, catchupRouter] time in
                if catchupRouter.route(.to(time)) { return }
                coordinator?.seek(time: time)
            },
            advance: onRemoteAdvance
        ), owner: coordinator)
    }

    func togglePlay() {
        let playing: Bool
        #if os(tvOS)
            playing = engine.isPlaying
        #else
            playing = isPlaying
        #endif
        if playing {
            coordinator.playerLayer?.pause()
        } else {
            coordinator.playerLayer?.play()
        }
        #if os(tvOS)
            // Reflect the new state immediately so the glyph flips without
            // waiting for the next state callback.
            engine.syncState(playing ? .paused : .bufferFinished)
        #endif
        scheduleHide()
    }

    var canAutoHideControls: Bool {
        #if os(tvOS)
            let playing = engine.isPlaying
            let panelOpen = isPanelOpen || isChannelBrowserOpen
        #else
            let playing = isPlaying
            let panelOpen = false
        #endif
        return PlayerControlsAutoHide.mayHide(
            isPlaying: playing, isPanelOpen: panelOpen || isSeeking,
            isSuppressed: PlayerControlsAutoHide.isSuppressed
        )
    }

    func scheduleHide() {
        chrome.schedule(mayHide: { canAutoHideControls })
    }

    func closePlayer() {
        #if os(macOS)
            MacPlayerWindowRouter.shared.close()
        #else
            dismiss()
        #endif
    }
}

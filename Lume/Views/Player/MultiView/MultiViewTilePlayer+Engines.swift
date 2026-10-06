//
//  MultiViewTilePlayer+Engines.swift
//  Lume
//
//  One video-only surface per playback engine, for `MultiViewTilePlayer`. Each
//  reuses the engine's existing coordinator — so a tile inherits its startup
//  watchdog and reconnect behaviour — but marks itself embedded, which declines
//  Picture in Picture and (for AVPlayer) the AirPlay route: those belong to the
//  single full-screen stream, not to one of four tiles.
//

import KSPlayer
import SwiftUI

// MARK: - KSPlayer

struct MultiViewKSTile: View {
    let media: PlayableMedia
    let isMuted: Bool
    let usesQuickStartupTimeout: Bool
    var onPlaybackStarted: () -> Void
    var onPlaybackFailed: () -> Void

    @StateObject private var coordinator = KSVideoPlayer.Coordinator()
    /// Bounded backoff for a *mid-stream* drop. KSPlayer has no safe in-place
    /// re-prepare (see `KSPlayerEngineView+Playback`), so a reconnect here bumps
    /// the id below, which tears the layer down and builds a fresh one.
    @State private var reconnector = PlaybackRetryController()
    @State private var reloadToken = 0
    @State private var hasStarted = false
    @State private var startupWatchdog: Task<Void, Never>?

    var body: some View {
        KSVideoPlayer(
            coordinator: coordinator,
            url: media.url,
            options: KSPlayerOptionsFactory.make(for: media, isEmbedded: true)
        )
        .onStateChanged { _, state in
            // Deferred so the mutations below never land inside a SwiftUI view
            // update pass, exactly as the full-screen KSPlayer host does it.
            DispatchQueue.main.async { handle(state) }
        }
        .id(reloadToken)
        .onAppear {
            coordinator.isMuted = isMuted
            startWatchdog()
        }
        .onDisappear {
            startupWatchdog?.cancel()
            reconnector.cancel()
            coordinator.resetPlayer()
        }
        .onChange(of: isMuted) { _, muted in coordinator.isMuted = muted }
    }

    private func handle(_ state: KSPlayerState) {
        // The layer is created during layout, so re-assert the mute as soon as
        // there is a player to apply it to.
        coordinator.isMuted = isMuted
        switch state {
        case .bufferFinished:
            reconnector.reset()
            guard !hasStarted else { return }
            hasStarted = true
            startupWatchdog?.cancel()
            onPlaybackStarted()
        case .error:
            startupWatchdog?.cancel()
            guard hasStarted else {
                onPlaybackFailed()
                return
            }
            // The stream had been playing and dropped — reconnect quietly rather
            // than replacing the tile with a failure badge.
            reconnector.scheduleRetry { reloadToken += 1 }
        default:
            break
        }
    }

    /// KSPlayer can hang in `.preparing`/`.buffering` indefinitely without ever
    /// emitting `.error`, which would leave the tile spinning forever.
    private func startWatchdog() {
        startupWatchdog?.cancel()
        let timeout = PlaybackPolicy.tileStartupTimeout(quick: usesQuickStartupTimeout)
        startupWatchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, !hasStarted else { return }
            onPlaybackFailed()
        }
    }
}

// MARK: - VLCKit

struct MultiViewVLCTile: View {
    let media: PlayableMedia
    let isMuted: Bool
    let usesQuickStartupTimeout: Bool
    var onPlaybackStarted: () -> Void
    var onPlaybackFailed: () -> Void

    @StateObject private var coordinator = VLCPlayerCoordinator(isEmbedded: true)

    var body: some View {
        VLCVideoContainer(coordinator: coordinator)
            .onAppear {
                coordinator.isMuted = isMuted
                coordinator.startupTimeout = PlaybackPolicy.tileStartupTimeout(quick: usesQuickStartupTimeout)
                coordinator.onPlaybackFailure = onPlaybackFailed
                coordinator.configure(media: media)
            }
            .onDisappear { coordinator.tearDown() }
            .onChange(of: isMuted) { _, muted in coordinator.isMuted = muted }
            .onChange(of: coordinator.hasStartedPlayback) { _, started in
                // libVLC applies the mute to the audio output, which only exists
                // once the stream is open.
                coordinator.isMuted = isMuted
                if started {
                    onPlaybackStarted()
                }
            }
    }
}

// MARK: - AVPlayer

struct MultiViewAVTile: View {
    let media: PlayableMedia
    let isMuted: Bool
    let usesQuickStartupTimeout: Bool
    var onPlaybackStarted: () -> Void
    var onPlaybackFailed: () -> Void

    @StateObject private var coordinator = AVPlayerCoordinator(isEmbedded: true)

    var body: some View {
        AVPlayerVideoContainer(coordinator: coordinator)
            .onAppear {
                coordinator.isMuted = isMuted
                coordinator.startupTimeout = PlaybackPolicy.tileStartupTimeout(quick: usesQuickStartupTimeout)
                coordinator.onPlaybackFailure = onPlaybackFailed
                coordinator.configure(media: media)
            }
            .onDisappear { coordinator.tearDown() }
            .onChange(of: isMuted) { _, muted in coordinator.isMuted = muted }
            .onChange(of: coordinator.hasStartedPlayback) { _, started in
                if started {
                    onPlaybackStarted()
                }
            }
    }
}

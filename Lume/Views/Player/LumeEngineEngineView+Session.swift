//
//  LumeEngineEngineView+Session.swift
//  Lume
//
//  Reports this engine's flags to the full-screen playback session — see
//  `PlaybackSession` and `View.reportsPlayback(to:…)`.
//

import SwiftUI

extension LumeEngineEngineView {
    var body: some View {
        engineBody.reportsPlayback(
            to: session, engine: .lumeEngine,
            report: .init(
                started: coordinator.hasStartedPlayback, buffering: coordinator.isBuffering,
                playing: coordinator.isPlaying, failed: loadFailed
            ),
            failureOverlay: $loadFailed
        )
    }
}

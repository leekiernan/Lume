//
//  LumeEngineCoordinator+PictureInPicture.swift
//  Lume
//
//  Picture in Picture for the LumeEngine coordinator: toggling (with the macOS
//  sample-buffer scaling fix) and staying alive in the background.
//

import Foundation
import LumeEngine

extension LumeEngineCoordinator {
    /// PiP starts and stops asynchronously; `syncPipState` picks up the result.
    func togglePictureInPicture() {
        #if os(macOS)
            let isStarting = pipBridge?.isActive == false
        #endif
        pipBridge?.toggle()
        #if os(macOS)
            // Sample-buffer PiP comes out cropped on macOS without this.
            if isStarting {
                MacPictureInPictureScaler.shared.pictureInPictureDidStart()
            } else {
                MacPictureInPictureScaler.shared.pictureInPictureDidStop()
            }
        #endif
    }

    /// Pause for backgrounding, unless Picture in Picture is carrying the video.
    /// Reads the bridge, not the `isPipActive` mirror, which can trail a tick.
    func pauseForBackground() {
        guard pipBridge?.isActive != true, isPlaying else { return }
        let session = session
        Task { await session?.pause() }
    }
}

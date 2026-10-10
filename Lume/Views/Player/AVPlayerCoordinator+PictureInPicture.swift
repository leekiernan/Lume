//
//  AVPlayerCoordinator+PictureInPicture.swift
//  Lume
//
//  PiP state for the AVPlayer engine, and the hand-off that lets the host
//  end the session when the PiP window is closed rather than restored.
//

import AVKit
import OSLog

// MARK: - AVPictureInPictureControllerDelegate

extension AVPlayerCoordinator: AVPictureInPictureControllerDelegate {
    /// Raised at *will* start: automatic PiP begins as the app leaves the
    /// foreground, and `pauseForBackground` must already see it by the time
    /// the scene reaches `.background`, before `didStart` arrives.
    func pictureInPictureControllerWillStartPictureInPicture(_: AVPictureInPictureController) {
        isPipActive = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
        isPipActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        isPipActive = false
        onPictureInPictureStop?()
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPipActive = false
        Logger.player.error("AVPlayer PiP failed to start: \(error.localizedDescription, privacy: .public)")
    }
}

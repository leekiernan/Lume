//
//  VLCPlayerCoordinator+PictureInPictureControls.swift
//  Lume
//
//  The transport VLC drives from the Picture in Picture window. In its own
//  file because the coordinator is at the project's file-length cap.
//

import VLCKit

/// VLCPictureInPictureMediaControlling — VLC drives playback from the PiP UI.
extension VLCPlayerCoordinator: VLCPictureInPictureMediaControlling {
    func play() {
        mediaPlayer.play()
    }

    func pause() {
        mediaPlayer.pause()
    }

    func seek(by offset: Int64, completion: @escaping () -> Void) {
        if catchup.route(.by(Double(offset) / 1000)) {
            completion()
            return
        }
        mediaPlayer.jump(withOffset: Int32(offset), completion: completion)
    }

    func mediaLength() -> Int64 {
        mediaPlayer.media?.length.value?.int64Value ?? 0
    }

    func mediaTime() -> Int64 {
        mediaPlayer.time.value?.int64Value ?? 0
    }

    func isMediaSeekable() -> Bool {
        mediaPlayer.isSeekable
    }

    func isMediaPlaying() -> Bool {
        mediaPlayer.isPlaying
    }
}

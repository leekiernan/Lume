//
//  AVPlayerCoordinator+Reconnect.swift
//  Lume
//
//  What an AVPlayer item failure earns — a bounded reconnect, like every other
//  engine (see `PlaybackPolicy`). Split from AVPlayerCoordinator.swift to keep
//  it within the length limit.
//

import AVFoundation
import OSLog

extension AVPlayerCoordinator {
    /// An item failure: before the first frame, a start failure unless this is
    /// the last engine (`PlaybackPolicy`); after it, a dropped stream. Both of
    /// the latter reconnect within the bounded budget and report only once it
    /// is spent — AVPlayer used to report every failure at once, so a stream
    /// that dropped mid-watch went straight to the failure overlay.
    func handleItemFailure() {
        guard hasStartedPlayback || retriesStartupErrors else {
            reportFailure()
            return
        }
        retry.scheduleRetry { [weak self] in self?.reconnect() }
        if retry.hasGivenUp { reportFailure() }
    }

    /// Re-open the current stream, VOD resuming where it dropped.
    private func reconnect() {
        guard var media = currentMedia else { return }
        let position = player.currentTime().seconds
        if !media.isLive, position.isFinite, position > 1 {
            media = media.resuming(at: position)
        }
        Logger.player.log("AVPlayer reconnect: reloading stream")
        load(media: media, reconnecting: true)
    }
}

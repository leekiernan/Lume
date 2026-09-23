//
//  HomeView+Playback.swift
//  Lume
//
//  Home's two live-playback entry points — split out to keep HomeView.swift
//  under the project's size limit. `startMultiView`/`playChannel` are passed
//  down to whichever rail or row shows a live channel.
//

import SwiftUI

extension HomeView {
    /// Opens Multi-View seeded with a channel from one of the rails, or the
    /// paywall when the viewer isn't on Lume Pro. Mirrors `LiveTVView`'s pair of
    /// the same name — the rails are a second entry point to the same feature.
    func startMultiView(with stream: LiveStream) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
        guard premium.isPremium else {
            showingPaywall = true
            return
        }
        #if os(macOS)
            // The window is a singleton, so it cannot be built around a launch:
            // hand the channel over and let the grid adopt it on appear.
            MultiViewLaunchQueue.shared.pending = [media]
            openWindow(id: "multiview")
        #elseif os(tvOS)
            // Presented by `MainTabView`, above the tab bar — see the router.
            router.multiViewLaunch = MultiViewLaunch(seed: [media])
        #else
            multiViewLaunch = MultiViewLaunch(seed: [media])
        #endif
    }

    func playChannel(_ stream: LiveStream) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist) else { return }
        if ExternalPlayback.open(media) { return }
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #else
            playingMedia = media
        #endif
    }
}

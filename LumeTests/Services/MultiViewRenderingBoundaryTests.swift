import AVFoundation
@testable import Lume
import Testing
import VLCKit

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Checks the coordinator/host boundary reused by tiles, without starting a
/// stream. Native SwiftUI identity, playback and remote focus need device checks.
@MainActor
struct MultiViewRenderingBoundaryTests {
    @Test func `embedded AV attachment keeps routing mute and teardown local to its tile`() {
        let first = AVPlayerCoordinator(isEmbedded: true)
        let second = AVPlayerCoordinator(isEmbedded: true)
        let firstLayer = AVPlayerLayer()
        let secondLayer = AVPlayerLayer()
        defer {
            first.tearDown()
            second.tearDown()
        }

        #expect(first.isEmbedded)
        #expect(second.isEmbedded)
        first.attach(layer: firstLayer)
        second.attach(layer: secondLayer)
        #expect(firstLayer.player === first.player)
        #expect(secondLayer.player === second.player)
        #expect(first.player !== second.player)
        let firstAllowsExternalPlayback = first.player.allowsExternalPlayback
        let secondAllowsExternalPlayback = second.player.allowsExternalPlayback
        #expect(firstAllowsExternalPlayback == false)
        #expect(secondAllowsExternalPlayback == false)
        #expect(!first.isPipSupported)
        #expect(!second.isPipSupported)
        #if os(iOS)
            #expect(!first.player.usesExternalPlaybackWhileExternalScreenIsActive)
        #endif

        first.isMuted = true
        second.isMuted = false
        first.isScaleAspectFill = true
        #expect(first.player.isMuted)
        #expect(!second.player.isMuted)
        #expect(firstLayer.videoGravity == .resizeAspectFill)
        #expect(secondLayer.videoGravity == .resizeAspect)

        first.tearDown()
        #expect(firstLayer.player == nil)
        #expect(secondLayer.player === second.player)
        #expect(!second.player.isMuted)
    }

    @Test func `sharing the AV surface does not disable fullscreen external playback`() {
        let coordinator = AVPlayerCoordinator()
        defer { coordinator.tearDown() }
        #expect(!coordinator.isEmbedded)
        #expect(coordinator.player.allowsExternalPlayback)
    }

    @Test func `the shared AV host resizes its existing layer rather than replacing the player`() {
        #if os(macOS)
            let host = AVPlayerHostNSView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        #else
            let host = AVPlayerHostUIView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        #endif
        let coordinator = AVPlayerCoordinator(isEmbedded: true)
        defer { coordinator.tearDown() }
        let layer = host.playerLayer
        coordinator.attach(layer: layer)

        for size in [CGSize(width: 320, height: 180), CGSize(width: 960, height: 540)] {
            host.frame = CGRect(origin: .zero, size: size)
            #if os(macOS)
                host.layout()
            #else
                host.layoutIfNeeded()
            #endif
            #expect(host.playerLayer === layer)
            #expect(layer.frame.size == size)
            #expect(layer.player === coordinator.player)
        }
    }

    @Test func `embedded VLC hosts decline PiP and teardown only their own drawable`() {
        let first = VLCPlayerCoordinator(isEmbedded: true)
        let second = VLCPlayerCoordinator(isEmbedded: true)
        let fullScreen = VLCPlayerCoordinator()
        let firstHost = VLCHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let secondHost = VLCHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        defer {
            first.tearDown()
            second.tearDown()
            fullScreen.tearDown()
        }

        first.attach(hostView: firstHost)
        second.attach(hostView: secondHost)
        #expect(first.mediaPlayer !== second.mediaPlayer)
        #expect(first.mediaController() == nil)
        #expect(second.mediaController() == nil)
        #expect(fullScreen.mediaController() != nil)
        #expect(first.bounds() == firstHost.bounds)
        #expect(second.bounds() == secondHost.bounds)
        #if os(macOS)
            #expect(!firstHost.wantsLayer)
            #expect(first.mediaPlayer.drawable as? NSView === firstHost)
            #expect(second.mediaPlayer.drawable as? NSView === secondHost)
        #else
            #expect(first.mediaPlayer.drawable as? VLCPlayerCoordinator === first)
            #expect(second.mediaPlayer.drawable as? VLCPlayerCoordinator === second)
        #endif

        first.tearDown()
        #expect(first.mediaPlayer.drawable == nil)
        #expect(second.mediaPlayer.drawable != nil)
        #expect(second.mediaController() == nil)
    }
}

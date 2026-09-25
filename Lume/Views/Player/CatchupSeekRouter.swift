//
//  CatchupSeekRouter.swift
//  Lume
//
//  The engine side of catch-up seeking. Every engine keeps one, loaded with
//  the media it is actually playing, and asks it two things: whether a seek or
//  skip belongs to the host (a catch-up programme seeks by opening a new
//  segment, never by byte-seeking the timeshift stream), and how to put its
//  own playhead on the clock (programme time for catch-up).
//
//  A reference type held by the engine rather than values read off the engine
//  view: several engines wire their callbacks once, in `onAppear`, so a
//  closure reading the view's `media` would keep answering for the stream the
//  player opened on long after a swap.
//

import Foundation

final class CatchupSeekRouter {
    /// The stream the engine has loaded. Updated wherever the engine loads.
    private(set) var media: PlayableMedia?
    /// The host's handler (`FullScreenPlayerView.handleCatchupSeek`). `nil`
    /// outside the full-screen player — Multi-View tiles seek natively.
    var onSeek: ((CatchupSeek) -> Void)?

    func load(_ media: PlayableMedia) {
        self.media = media
    }

    /// Hands `seek` to the host when the loaded stream is catch-up, and says
    /// whether it did; the engine seeks natively when this returns `false`.
    func route(_ seek: CatchupSeek) -> Bool {
        guard media?.catchup != nil, let onSeek else { return false }
        onSeek(seek)
        return true
    }

    /// The engine's playhead onto the clock — see `PlaybackClock.applyEngine`.
    func report(position: TimeInterval, to clock: PlaybackClock) {
        clock.applyEngine(position: position, of: media)
    }

    func report(duration: TimeInterval, to clock: PlaybackClock) {
        clock.applyEngine(duration: duration, of: media)
    }

    /// The loaded stream's own playhead for a clock position — what a
    /// reconnect that re-opens this stream in place must resume at.
    func enginePosition(forClock position: TimeInterval) -> TimeInterval {
        media?.enginePosition(position) ?? position
    }
}

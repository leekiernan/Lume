//
//  PlayerChrome.swift
//  Lume
//
//  When the player's controls are drawn, the same for every engine. KSPlayer
//  and LumeEngine held them back until the first frame while VLC and AVPlayer
//  drew them over the loading spinner from the start.
//

enum PlayerChrome {
    /// Controls wait for the stream's first frame — a Play button over a
    /// spinner looks like a paused player — except while a catch-up segment
    /// loads, where the scrubber the viewer is seeking with stays up.
    static func drawsControls(requested: Bool, started: Bool, catchupSegmentLoading: Bool = false, failed: Bool) -> Bool {
        requested && (started || catchupSegmentLoading) && !failed
    }
}

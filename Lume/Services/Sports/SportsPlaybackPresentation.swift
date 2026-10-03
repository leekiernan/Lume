//
//  SportsPlaybackPresentation.swift
//  Lume
//
//  When to put the player up after Watch on a Sports surface. Watch is often
//  pressed inside a sheet or cover — a game's detail, the channel picker —
//  and a sheet's dismissal isn't done when its binding drops to `nil`. A
//  full-screen player presented while it is still animating out is torn down
//  and re-presented once it has gone: two players, two stream opens, and the
//  second trips the provider's connection cap (LumeEngine fails, KSPlayer gets
//  HTTP 429). So media chosen from a sheet waits here until the sheet's
//  `onDismiss`. Both hubs, both Home rails and the league screen share it.
//

struct SportsPlaybackPresentation {
    /// What the player shows; the full-screen player binds to it.
    var playing: PlayableMedia?
    /// Chosen from a sheet that is still closing.
    private var pending: PlayableMedia?

    /// Plays `media` now, or — when a sheet or cover is closing — once it has.
    mutating func play(_ media: PlayableMedia, afterSheet: Bool) {
        if afterSheet {
            pending = media
        } else {
            playing = media
        }
    }

    /// The sheet's dismissal has finished: whatever waited can play.
    mutating func sheetDidDismiss() {
        guard let media = pending else { return }
        pending = nil
        playing = media
    }
}

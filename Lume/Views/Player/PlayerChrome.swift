//
//  PlayerChrome.swift
//  Lume
//
//  When the player's controls are drawn, the same for every engine. Controls
//  wait for the first frame rather than covering the loading spinner.
//

enum PlayerChrome {
    /// A new URL within an already-started programme is a seek, not a new
    /// title opening. Consecutive seeks retain that presentation until a frame
    /// arrives; an initial open or another programme must still wait for one.
    static func keepsCatchupControls(previous: CatchupTimeline?, next: CatchupTimeline?, started: Bool, alreadyLoading: Bool) -> Bool {
        next?.isSameProgramme(as: previous) == true && (started || alreadyLoading)
    }

    /// Controls wait for the stream's first frame — a Play button over a
    /// spinner looks like a paused player — except while a catch-up segment
    /// loads, where the scrubber the viewer is seeking with stays up.
    static func drawsControls(requested: Bool, started: Bool, catchupSegmentLoading: Bool = false, failed: Bool) -> Bool {
        requested && (started || catchupSegmentLoading) && !failed
    }
}

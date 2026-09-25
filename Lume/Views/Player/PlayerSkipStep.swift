//
//  PlayerSkipStep.swift
//  Lume
//
//  What the transport's skip buttons show for a step: the SF Symbols with the
//  number in the glyph, and the VoiceOver labels that must say the same. The
//  step itself comes from `PlayableMedia.skipInterval(default:)`, so every
//  overlay switches to a drop-in minute on catch-up together.
//

import SwiftUI

struct PlayerSkipStep {
    let seconds: TimeInterval

    /// `gobackward.15`, `gobackward.60`, … — SF Symbols ships these for the
    /// steps the player uses (10, 15, 60).
    var backSymbol: String {
        "gobackward.\(Int(seconds))"
    }

    var forwardSymbol: String {
        "goforward.\(Int(seconds))"
    }

    /// The iOS / macOS overlays' labels, which cover their two steps: the
    /// standard 15 seconds and catch-up's minute. (The tvOS transport buttons
    /// carry no label of their own.)
    var backLabel: LocalizedStringKey {
        isMinute ? "Skip back 1 minute" : "Skip back 15 seconds"
    }

    var forwardLabel: LocalizedStringKey {
        isMinute ? "Skip forward 1 minute" : "Skip forward 15 seconds"
    }

    private var isMinute: Bool {
        seconds == CatchupSeekPlanner.step
    }
}

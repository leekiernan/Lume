//
//  OutroTrigger.swift
//  Lume
//
//  Decides when the end-of-episode Next Episode button arms, refining the
//  legacy fraction-of-duration heuristic with IntroDB's decoded outro segment.
//

import Foundation

/// Pure arm-time arithmetic for the in-player Next Episode button.
///
/// IntroDB is keyed only by series IMDb id + season + episode — there is no
/// runtime or hash check — while IPTV providers ship their own encodes with
/// different intros, ad breaks and trailing slates. A segment that doesn't
/// match the stream being played must therefore never win, so every window is
/// sanity-checked against the engine-reported duration before it is trusted.
nonisolated enum OutroTrigger {
    /// Without credit timings, offer the next episode during the final 10%,
    /// but never spend more than two minutes over the remaining plot.
    private static let fallbackFraction = 0.1
    private static let maxFallbackLead: TimeInterval = 120

    /// How far before the end of the file the credits may end and still be
    /// plausible for this encode.
    private static let maxEndSlack: TimeInterval = 90

    /// How far an outro window may run *past* the reported duration and still
    /// be believed. A second or two is ordinary rounding between the container
    /// and the engine; more than that means the segment was timed against a
    /// longer cut than the one playing, so the whole window is suspect.
    private static let maxEndOvershoot: TimeInterval = 2

    /// The absolute time, in seconds, at which the Next Episode button should
    /// arm — or `nil` when `duration` is unknown or the stream is live, in
    /// which case callers keep whatever behaviour they had.
    ///
    /// Without a trusted outro, use the final 10% capped at two minutes.
    /// Trusted credits retain their own start time, even if longer than that
    /// fallback window, but never arm before the 90% watched-completion line.
    /// Prompt timing is a presentation policy; it does not change when the
    /// writer counts a movie or episode as watched.
    static func armTime(outro: IntroSegments.Segment?, duration: TimeInterval) -> TimeInterval? {
        guard duration > 1 else { return nil }

        let fallback = duration - min(duration * fallbackFraction, maxFallbackLead)

        guard let outro,
              outro.duration >= IntroSegments.minimumUsableDuration,
              outro.start > 0,
              outro.start < duration,
              isEndPlausible(outro.end, duration: duration)
        else {
            return fallback
        }

        return max(outro.start, duration * WatchCompletion.threshold)
    }

    /// Whether credits ending at `end` are plausible for a file of `duration`.
    ///
    /// Slack is positive when the credits finish before the file does and
    /// negative when the window runs past the end of this encode. Both
    /// directions are bounded: a window ending far too early was timed against
    /// a different cut, and one ending past the file end could not have come
    /// from this stream at all.
    private static func isEndPlausible(_ end: TimeInterval, duration: TimeInterval) -> Bool {
        let slack = duration - end
        return slack <= maxEndSlack && slack >= -maxEndOvershoot
    }
}

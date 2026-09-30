//
//  EpisodeOverlayMachine.swift
//  Lume
//
//  What the in-player episode affordances are doing — Skip Intro / Skip Recap,
//  the tvOS Next Episode button, auto-advance — as one explicit state instead
//  of two overlays each re-deriving "should I show?" from the clock on every
//  tick.
//
//  The clock stays outside: it ticks ten times a second, and nearly every tick
//  changes nothing. `zone(at:…)` reduces it to where the playhead is relative
//  to the episode's windows, and the host sends only a change of zone — a
//  window boundary crossed by playback or jumped by a seek. Everything else is
//  a discrete event: settings, a dismissal, a press, a new episode.
//
//  Neither pausing nor the controls are events: an offer stands through both.
//  Where the button sits while the controls show is layout, not state
//  (`PlayerEpisodeOverlays` lifts it above them).
//
//  Pure: `PlayerEpisodeOverlays` feeds events in and performs the effects.
//

import Foundation

struct EpisodeOverlayMachine: Equatable {
    /// Where the playhead is, relative to the episode's windows.
    enum Zone: Equatable {
        /// No established position or duration yet.
        case unknown
        case recap(IntroSegments.Segment)
        case intro(IntroSegments.Segment)
        case content
        /// Past the Next Episode arm point (`OutroTrigger`).
        case outro
        /// The last few seconds, where auto-advance fires.
        case ending
    }

    /// What is on offer.
    enum Offer: Equatable {
        case skipRecap(IntroSegments.Segment)
        case skipIntro(IntroSegments.Segment)
        case nextEpisode
    }

    enum State: Equatable {
        case none
        case offering(Offer)
        /// The viewer dismissed it; stays down until the zone offers something
        /// else.
        case dismissed(Offer)
    }

    /// Which affordances are switched on — settings, Premium and platform
    /// combined by the host, so the machine never reads them itself.
    struct Config: Equatable {
        var skipButton = false
        /// The tvOS outro button. Other platforms have an always-present Next
        /// Episode button in the transport row instead.
        var nextButton = false
        var autoAdvance = false
        /// Whether there is a next episode at all.
        var hasNextEpisode = false
    }

    enum Event: Equatable {
        case configure(Config)
        case zone(Zone)
        case dismiss
        case activate
        /// A different episode: dismissals and the auto-advance latch belong to
        /// the one before.
        case reset
    }

    enum Effect: Equatable {
        /// To the given time, in seconds.
        case seek(TimeInterval)
        case playNext
    }

    private(set) var state: State = .none
    private(set) var config = Config()
    private(set) var zone: Zone = .unknown
    /// Auto-advance fires once per episode, however many ending ticks follow.
    private var didAdvance = false
    /// A dismissed Next Episode stays dismissed for the rest of the episode;
    /// a dismissed skip only for its own window.
    private var nextDismissed = false

    /// What is on offer right now, if anything.
    var activeOffer: Offer? {
        guard case let .offering(offer) = state else { return nil }
        return offer
    }

    /// Applies `event`, returning the effects to perform.
    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .configure(config):
            self.config = config
        case let .zone(zone):
            return enter(zone)
        case .dismiss:
            guard case let .offering(offer) = state else { return [] }
            if offer == .nextEpisode { nextDismissed = true }
            state = .dismissed(offer)
            return []
        case .activate:
            return activate()
        case .reset:
            didAdvance = false
            nextDismissed = false
            state = .none
        }
        state = settle()
        return []
    }

    private mutating func enter(_ zone: Zone) -> [Effect] {
        self.zone = zone
        state = settle()
        guard zone == .ending, config.autoAdvance, config.hasNextEpisode, !didAdvance else { return [] }
        didAdvance = true
        return [.playNext]
    }

    private mutating func activate() -> [Effect] {
        guard let offer = activeOffer else { return [] }
        state = .none
        switch offer {
        case let .skipRecap(segment), let .skipIntro(segment): return [.seek(segment.end)]
        case .nextEpisode: return [.playNext]
        }
    }

    /// The state the current zone and config call for, keeping a dismissal of
    /// the same offer.
    private func settle() -> State {
        guard let offer = offer(for: zone) else { return .none }
        if case let .dismissed(dismissed) = state, dismissed == offer { return state }
        if offer == .nextEpisode, nextDismissed { return .dismissed(offer) }
        return .offering(offer)
    }

    private func offer(for zone: Zone) -> Offer? {
        switch zone {
        case let .recap(segment): config.skipButton ? .skipRecap(segment) : nil
        case let .intro(segment): config.skipButton ? .skipIntro(segment) : nil
        case .outro, .ending: config.nextButton && config.hasNextEpisode ? .nextEpisode : nil
        case .unknown, .content: nil
        }
    }

    // MARK: - Zone

    /// Where `current` sits in an episode of `duration` with `segments`. A
    /// recap wins over an intro where both match (some shows tag a "previously
    /// on" ahead of the titles); windows shorter than
    /// `IntroSegments.minimumUsableDuration` don't count.
    static func zone(current: TimeInterval, duration: TimeInterval, segments: IntroSegments?) -> Zone {
        guard current > 0 else { return .unknown }
        if let recap = usable(segments?.recap, containing: current) { return .recap(recap) }
        if let intro = usable(segments?.intro, containing: current) { return .intro(intro) }
        guard duration > 1 else { return .content }
        let remaining = duration - current
        if remaining <= 3 || current / duration >= 0.995 { return .ending }
        if let armTime = OutroTrigger.armTime(outro: segments?.outro, duration: duration), current >= armTime {
            return .outro
        }
        return .content
    }

    private static func usable(_ segment: IntroSegments.Segment?, containing time: TimeInterval) -> IntroSegments.Segment? {
        guard let segment, segment.duration >= IntroSegments.minimumUsableDuration,
              time >= segment.start, time < segment.end
        else { return nil }
        return segment
    }
}

// MARK: - Journal names

extension EpisodeOverlayMachine.State {
    var logName: String {
        switch self {
        case .none: "none"
        case let .offering(offer): "offering(\(offer.logName))"
        case let .dismissed(offer): "dismissed(\(offer.logName))"
        }
    }
}

extension EpisodeOverlayMachine.Offer {
    var logName: String {
        switch self {
        case let .skipRecap(segment): "skipRecap \(segment.logName)"
        case let .skipIntro(segment): "skipIntro \(segment.logName)"
        case .nextEpisode: "nextEpisode"
        }
    }
}

extension IntroSegments.Segment {
    var logName: String {
        "\(Int(start))–\(Int(end)) s"
    }
}

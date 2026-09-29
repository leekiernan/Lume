//
//  LaunchCover.swift
//  Lume
//
//  Whether the launch splash still covers the app. On tvOS, Home's first
//  seconds were a black backdrop and an empty hero until the hero or a row
//  loaded; the splash (the launch screen's logo, carried on) covers that and
//  lifts once Home has something to show.
//
//  Pure: `LaunchSplashModel` feeds in what Home reports and the timeout.
//

import Foundation

struct LaunchCover: Equatable {
    enum State: Equatable {
        case covering
        case revealed(Reason)
    }

    enum Reason: String, Equatable {
        /// Home has its hero, or has settled on showing none.
        case homeReady
        /// Another tab opened first: Home's loading isn't on screen.
        case homeNotShown
        /// Never hold the app back longer than this.
        case timedOut
    }

    enum Event: Equatable {
        case homeShowed(SectionSurfaceDisplay, feedSettled: Bool)
        case otherTabShown
        case timedOut
    }

    /// The most the splash waits for Home.
    static let longest: Duration = .seconds(8)

    private(set) var state: State = .covering

    var isCovering: Bool {
        state == .covering
    }

    /// Applies `event`; true when it lifts the cover.
    mutating func handle(_ event: Event) -> Bool {
        guard isCovering else { return false }
        switch event {
        case let .homeShowed(display, feedSettled):
            guard Self.homeIsReady(display, feedSettled: feedSettled) else { return false }
            state = .revealed(.homeReady)
        case .otherTabShown:
            state = .revealed(.homeNotShown)
        case .timedOut:
            state = .revealed(.timedOut)
        }
        return true
    }

    /// Home has something to show: its hero, or a settled decision without
    /// one. `disabled` is also Home's first frame, before the hero is seeded,
    /// so it only counts once the feeds have settled.
    static func homeIsReady(_ display: SectionSurfaceDisplay, feedSettled: Bool) -> Bool {
        switch display {
        case .noPlaylists, .empty:
            true
        case let .content(hero):
            switch hero {
            case .content, .empty, .failed: true
            case .loading: false
            case .disabled: feedSettled
            }
        }
    }
}

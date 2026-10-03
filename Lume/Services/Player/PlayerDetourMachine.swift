//
//  PlayerDetourMachine.swift
//  Lume
//
//  A detour: the player left a film (or episode) for a live game, and owes the
//  viewer the way back. The machine holds where to return to and when its
//  "Back to …" pill shows: for a while on arrival, then only alongside the
//  player controls, until the viewer goes back or the player closes. Pure —
//  the player's layer performs the return it asks for.
//

import Foundation

nonisolated struct PlayerDetourMachine: Equatable {
    /// Where the viewer left, and how far in.
    struct Origin: Equatable {
        let media: PlayableMedia
        let position: TimeInterval
    }

    enum State: Equatable {
        case none
        /// Just arrived: the pill shows regardless of the controls.
        case arriving(Origin)
        /// Settled: the pill shows with the controls.
        case resting(Origin)
    }

    enum Event: Equatable {
        /// The player is leaving `origin` for a live game.
        case began(Origin)
        case arrivalElapsed
        /// Back was pressed with nothing else to close.
        case backPressed
        /// The player went back to the origin some other way, or closed.
        case ended
    }

    enum Effect: Equatable {
        /// Switch back to this media (a copy resuming at the saved position).
        case returnTo(PlayableMedia)
    }

    private(set) var state: State = .none

    var origin: Origin? {
        switch state {
        case .none: nil
        case let .arriving(origin), let .resting(origin): origin
        }
    }

    func pillVisible(controlsVisible: Bool) -> Bool {
        switch state {
        case .none: false
        case .arriving: true
        case .resting: controlsVisible
        }
    }

    @discardableResult
    mutating func handle(_ event: Event) -> [Effect] {
        switch (event, state) {
        case let (.began(origin), .none):
            state = .arriving(origin)
            return []
        case (.began, _):
            // Already detouring: hopping between live games keeps the first
            // way back — the film is where the viewer came from.
            return []
        case let (.arrivalElapsed, .arriving(origin)):
            state = .resting(origin)
            return []
        case let (.backPressed, .arriving(origin)), let (.backPressed, .resting(origin)):
            state = .none
            return [.returnTo(origin.media.resuming(at: origin.position))]
        case (.ended, _):
            state = .none
            return []
        default:
            return []
        }
    }
}

//
//  FullScreenPlayerView+Session.swift
//  Lume
//
//  Carries out what the playback session asks for — see
//  `PlaybackSessionMachine`. The Trakt scrobble follows the session's state
//  (a stall is not a pause), progress is saved at its boundaries, and an
//  engine that can't start hands over to the next one.
//

import SwiftUI

/// Which engine is on which stream; see `FullScreenPlayerView.engineMount`.
struct EngineMount: Equatable {
    let engine: PlayerEngineKind
    let mediaID: String
    let identity: [Int]
}

extension FullScreenPlayerView {
    func installSessionEffects() {
        session.perform = { effect in
            switch effect {
            case let .scrobble(action):
                switch action {
                case .start: updateTraktScrobble(isPlaying: true)
                case .pause: updateTraktScrobble(isPlaying: false)
                case .stop: stopTraktScrobble()
                }
            case let .persistProgress(holdingLive):
                persistProgressDetached(holdingLive: holdingLive)
            case .fallBackToNextEngine:
                fallBackToNextEngine()
            }
        }
    }
}

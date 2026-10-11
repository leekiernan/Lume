//
//  TraktPlaybackScrobbler.swift
//  Lume
//
//  Small playback-state machine that de-duplicates Trakt scrobble events.
//

import Foundation

@MainActor
final class TraktPlaybackScrobbler {
    typealias Sender = @MainActor (TraktScrobbleTarget, TraktScrobbleAction, Double) -> Void

    private enum Phase {
        case idle
        case playing
        case paused
    }

    private let send: Sender
    private var target: TraktScrobbleTarget?
    private var phase = Phase.idle
    private var lastProgress = 0.0

    init(send: @escaping Sender = { target, action, progress in
        TraktService.shared.scrobble(target, action: action, progress: progress)
    }) {
        self.send = send
    }

    /// Starts a new Trakt watching session, or resumes a paused one. Repeated
    /// playing notifications from an engine are ignored. If an engine/media
    /// transition coalesces away the explicit stop, settle the old target first.
    func playbackStarted(target newTarget: TraktScrobbleTarget, progress: Double) {
        if let target, target != newTarget, phase != .idle {
            sendStop(target, progress: lastProgress)
            phase = .idle
        }

        target = newTarget
        lastProgress = Self.validProgress(progress)
        guard phase != .playing else { return }
        send(newTarget, .start, lastProgress)
        phase = .playing
    }

    /// Pauses only a session that was actually started. Engine buffering and
    /// duplicate state callbacks therefore cannot manufacture orphan pauses.
    func playbackPaused(target currentTarget: TraktScrobbleTarget, progress: Double) {
        guard target == currentTarget, phase == .playing else { return }
        lastProgress = Self.validProgress(progress)
        // Trakt rejects these with 422; do not manufacture a 1% resume point
        // just because the viewer paused briefly near the beginning.
        if lastProgress >= 1 { send(currentTarget, .pause, lastProgress) }
        phase = .paused
    }

    /// Ends the current session when the player closes or changes media. Trakt
    /// rejects stop progress below 1%, so an early exit uses a separate discard
    /// operation: settle watching, then delete the temporary playback entry.
    func playbackStopped(target currentTarget: TraktScrobbleTarget, progress: Double) {
        guard target == currentTarget, phase != .idle else { return }
        lastProgress = Self.validProgress(progress)
        sendStop(currentTarget, progress: lastProgress)
        target = nil
        phase = .idle
        lastProgress = 0
    }

    nonisolated static func progress(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        guard elapsed.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return validProgress(elapsed / duration * 100)
    }

    private nonisolated static func validProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 100)
    }

    private func sendStop(_ target: TraktScrobbleTarget, progress: Double) {
        send(target, progress < 1 ? .discard : .stop, progress)
    }
}

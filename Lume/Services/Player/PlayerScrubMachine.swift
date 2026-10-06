import Foundation

/// The tvOS progress bar owns a preview, not the engine's playback clock.
/// Leave preview mode before issuing engine commands: seeks may resume playback
/// synchronously, and every exit must release the chrome's panel hold.
nonisolated struct PlayerScrubMachine {
    struct Completion: Equatable {
        let seekTarget: TimeInterval?
        let resume: Bool
    }

    private struct Session {
        var target: TimeInterval
        let wasPlaying: Bool
        var observedPause: Bool
    }

    private var session: Session?

    var isScrubbing: Bool {
        session != nil
    }

    var target: TimeInterval {
        session?.target ?? 0
    }

    /// Returns whether the caller needs to pause the engine.
    mutating func begin(current: TimeInterval, isPlaying: Bool) -> Bool {
        guard session == nil else { return false }
        session = Session(target: current.isFinite ? max(current, 0) : 0,
                          wasPlaying: isPlaying, observedPause: !isPlaying)
        return isPlaying
    }

    mutating func move(to target: TimeInterval) {
        guard target.isFinite else { return }
        session?.target = max(target, 0)
    }

    /// Select restores the original play state; dedicated Play/Pause commits
    /// and plays even when the viewer entered from an already-paused picture.
    mutating func finish(duration: TimeInterval, commit: Bool, play: Bool = false) -> Completion? {
        guard let session else { return nil }
        self.session = nil
        let duration = duration.isFinite ? max(duration, 0) : 0
        return Completion(seekTarget: commit ? min(session.target, duration) : nil,
                          resume: play || session.wasPlaying)
    }

    /// Playback can also resume through the system remote or an engine's seek
    /// completion. Abandon the preview without another seek or play command.
    /// A still-playing callback before the requested pause is not a resume.
    @discardableResult
    mutating func playbackChanged(isPlaying: Bool) -> Bool {
        guard let session else { return false }
        if !isPlaying {
            self.session?.observedPause = true
            return false
        }
        guard session.observedPause else { return false }
        self.session = nil
        return true
    }

    mutating func reset() {
        session = nil
    }
}

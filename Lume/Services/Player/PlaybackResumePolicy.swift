import Foundation

/// A title abandoned before one percent has no useful resume point. Unknown
/// durations cannot establish that threshold and must retain their position.
nonisolated enum PlaybackResumePolicy {
    static func discardsProgress(position: TimeInterval, duration: TimeInterval) -> Bool {
        position.isFinite && duration.isFinite && position >= 0 && duration > 0
            && position / duration < 0.01
    }
}

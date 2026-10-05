import Foundation
import Observation

/// The page dots alone observe this clock. Paging, focus and animation remain
/// with each carousel; pausing holds an empty bar for a full dwell on return.
@Observable
final class HeroAutoAdvanceClock {
    static let tickInterval: Duration = .milliseconds(50)
    private(set) var progress: Double = 0
    private let step: Double

    init(interval: Duration = .seconds(6)) {
        let parts = interval.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        precondition(seconds > 0, "A hero dwell must be positive")
        step = 0.05 / seconds
    }

    /// Returns true once per full bar, resetting before the owner pages so a
    /// settling animation cannot trigger another immediate advance.
    func tick(isPaused: Bool, hasMultipleItems: Bool = true) -> Bool {
        guard hasMultipleItems, !isPaused else {
            reset()
            return false
        }
        if progress >= 1 {
            reset()
            return true
        }
        progress = min(progress + step, 1)
        return false
    }

    /// Observation still publishes equal writes; idle/paused ticks must not
    /// redraw the indicator twenty times a second.
    @discardableResult
    func reset() -> Bool {
        guard progress != 0 else { return false }
        progress = 0
        return true
    }
}

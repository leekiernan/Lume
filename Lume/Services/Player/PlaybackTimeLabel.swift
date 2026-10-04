import Foundation

/// Elapsed media time, not an EPG wall-clock time or a signed skip distance.
nonisolated enum PlaybackTimeLabel {
    /// Keeps the scrubbers' existing fixed-digit m:ss / h:mm:ss presentation.
    static func clock(_ position: TimeInterval) -> String {
        let total = Int(seconds(position))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? "\(hours):" + String(format: "%02d:%02d", minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    /// Skip badges retain their native, locale-aware Duration presentation.
    static func localized(_ position: TimeInterval, locale: Locale = .current) -> String {
        let clamped = seconds(position)
        let pattern: Duration.TimeFormatStyle.Pattern = clamped >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(clamped).formatted(.time(pattern: pattern).locale(locale))
    }

    private static func seconds(_ position: TimeInterval) -> TimeInterval {
        // A corrupt engine timestamp must not trap in Double-to-Int conversion.
        guard position.isFinite, position >= 0, position < Double(Int.max) else { return 0 }
        return position.rounded(.down)
    }
}

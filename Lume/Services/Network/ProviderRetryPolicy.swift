import Foundation

/// Attempt budget only. Authentication refresh, error classification and
/// request/phase spacing belong to the provider, not to a universal request loop.
nonisolated struct ProviderRetryPolicy {
    let maxAttempts: Int

    static let catalog = ProviderRetryPolicy(maxAttempts: 3)

    /// Attempts are one-based; three attempts mean delays of 2s and 4s.
    func delay(afterFailedAttempt attempt: Int) -> Double? {
        guard attempt > 0, attempt < maxAttempts else { return nil }
        return pow(2, Double(attempt))
    }
}

nonisolated enum ProviderRequestSpacing {
    static func remaining(
        minimum: Duration, since finishedAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant = .now
    ) -> Duration {
        guard let finishedAt else { return .zero }
        return max(.zero, min(minimum, minimum - (now - finishedAt)))
    }
}

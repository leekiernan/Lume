import Foundation

/// Coverage may tolerate a repeated real shrink, but unreadable storage never
/// grants deletion authority and never spends that tolerance budget.
nonisolated enum CatalogSweepPolicy {
    nonisolated enum Decision: Equatable {
        case sweep
        case hold(skips: Int)
        case acceptShrink(skips: Int)
        case unreadable
    }

    /// Sweeps when the payload covers at least 10% of the stored rows.
    /// Otherwise holds — twice. Coverage is measured against the stored rows,
    /// which a skipped sweep never reduces, so a subscription that genuinely
    /// shrinks below the floor (a downgraded plan, a replaced lineup) would be
    /// refused on every sync and strand its dead rows forever. A malformed
    /// payload is transient and won't repeat that often; a real shrink repeats
    /// every sync, so the third consecutive low-coverage pass accepts it. An
    /// unreadable stored count never sweeps and never spends a skip.
    static func decide(seenCount: Int, storedCount: Int?, previousSkips: Int) -> Decision {
        guard let storedCount else { return .unreadable }
        if Double(seenCount) >= Double(storedCount) * 0.1 { return .sweep }
        let skips = previousSkips + 1
        return skips > 2 ? .acceptShrink(skips: skips) : .hold(skips: skips)
    }
}

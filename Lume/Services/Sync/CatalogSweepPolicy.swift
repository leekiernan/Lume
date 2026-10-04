import Foundation

/// Coverage may tolerate a repeated real shrink, but unreadable storage never
/// grants deletion authority and never spends that tolerance budget.
nonisolated enum CatalogSweepPolicy {
    enum Decision: Equatable {
        case sweep
        case hold(skips: Int)
        case acceptShrink(skips: Int)
        case unreadable
    }

    static func decide(seenCount: Int, storedCount: Int?, previousSkips: Int) -> Decision {
        guard let storedCount else { return .unreadable }
        if Double(seenCount) >= Double(storedCount) * 0.1 { return .sweep }
        let skips = previousSkips + 1
        return skips > 2 ? .acceptShrink(skips: skips) : .hold(skips: skips)
    }
}

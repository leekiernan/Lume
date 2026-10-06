import Foundation

/// A Match Centre push carries immutable snapshots, never managed catalog
/// objects or callbacks into a rail that can disappear when its tab unmounts.
nonisolated struct SportsMatchRoute: Hashable {
    let fixture: SportsFixture
    let resolved: [ResolvedChannel]
    let visibilityToken: String

    /// A restored route must not reuse channels hidden since it was opened.
    /// The detail screen resolves afresh when its seed no longer applies.
    func channels(visibleUnder token: String) -> [ResolvedChannel] {
        visibilityToken == token ? resolved : []
    }

    /// Route identity stays fixed while the visible score/status follows the
    /// store. Keep the seed for highlights absent from the followed-league cache.
    /// A race-session route must not turn back into its parent weekend.
    func currentFixture(in fixtures: [SportsFixture], now: Date = Date()) -> SportsFixture {
        guard let latest = fixtures.first(where: { $0.id == fixture.id || $0.id == fixture.eventId }) else {
            return fixture
        }
        guard fixture.sessionKind != nil, latest.id != fixture.id else { return latest }
        return latest.expandedBySession(now: now).first(where: { $0.id == fixture.id }) ?? fixture
    }
}

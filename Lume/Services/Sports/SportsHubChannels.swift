import Foundation

/// One visibility-scoped channel answer for hub heroes, rails and sheets.
/// Request ownership stays with the two load machines. A known empty current
/// answer is authoritative; highlights only fill fixtures not yet resolved.
nonisolated struct SportsHubChannels {
    let resolved: [String: [ResolvedChannel]]

    init(
        resolution: SportsFixtureResolutionMachine,
        highlights: SportsHighlightsLoadMachine,
        visibilityToken: String
    ) {
        resolved = highlights.result(for: visibilityToken).resolved.merging(resolution.resolved(for: visibilityToken)) { _, current in
            current
        }
    }

    var availableIDs: Set<String> {
        Set(resolved.filter { !$0.value.isEmpty }.map(\.key))
    }
}

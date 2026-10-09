import Foundation

/// A supplementary metadata result is not proof that the provider refreshed,
/// nor is a usable provider guide proof that enrichment succeeded.
nonisolated struct EPGEnrichmentReport: Equatable {
    enum State: String {
        case disabled, unsupported, downloaded, unchanged, cached, deferred, unavailable, interrupted
    }

    let state: State
    var verifiedStations = 0
    var cachedProgrammes = 0
    var matchedProgrammes = 0
    var changedProgrammes = 0
    var checkedAt: Date?
    var retryAt: Date?
    var feedID: EPGEnrichmentFeed.Identifier?
    var feeds: [EPGEnrichmentReport] = []

    var hasWarning: Bool {
        state == .unavailable || state == .deferred || feeds.contains(where: \.hasWarning)
    }

    static func combining(_ feeds: [Self], enabled: Bool) -> Self {
        let precedence: [State] = [.unavailable, .deferred, .downloaded, .unchanged, .cached, .unsupported]
        let state = enabled ? precedence.first(where: { candidate in feeds.contains { $0.state == candidate } }) ?? .unsupported : .disabled
        return Self(state: state, verifiedStations: feeds.reduce(0) { $0 + $1.verifiedStations },
                    cachedProgrammes: feeds.reduce(0) { $0 + $1.cachedProgrammes },
                    matchedProgrammes: feeds.reduce(0) { $0 + $1.matchedProgrammes },
                    changedProgrammes: feeds.reduce(0) { $0 + $1.changedProgrammes },
                    checkedAt: feeds.compactMap(\.checkedAt).min(), retryAt: feeds.compactMap(\.retryAt).min(), feeds: feeds)
    }

    var message: String {
        switch state {
        case .disabled: String(localized: "EPGShare: off")
        case .unsupported: String(localized: "EPGShare: no verified stations")
        case .downloaded: String(localized: "EPGShare: downloaded")
        case .unchanged: String(localized: "EPGShare: unchanged")
        case .cached: String(localized: "EPGShare: cached")
        case .deferred: String(localized: "EPGShare: retry deferred")
        case .unavailable: String(localized: "EPGShare: unavailable")
        case .interrupted: String(localized: "EPGShare: interrupted; will retry")
        }
    }
}

import Foundation

/// Metadata feeds never own a timetable. Identity, cache and scheduling are
/// separate per feed, while the sync publishes their additions together.
nonisolated struct EPGEnrichmentFeed {
    enum Identifier: String, CaseIterable {
        case usPBS = "us-locals"
        case britain = "uk"

        var label: String {
            self == .usPBS ? "US PBS" : "UK"
        }

        var checkedKey: String {
            // A registry expansion needs a publication even if the previous scope was checked recently.
            self == .usPBS ? EPGEnrichmentSettings.checkedKey : EPGEnrichmentSettings.checkedKey + ".uk.v2"
        }

        var failedKey: String {
            self == .usPBS ? EPGEnrichmentSettings.failedKey : EPGEnrichmentSettings.failedKey + ".uk"
        }

        var refreshInterval: TimeInterval {
            self == .usPBS ? 24 * 3600 : 12 * 3600
        }
    }

    let id: Identifier
    let url: URL
    let cacheURL: URL?

    static func production(cacheURL: URL? = EPGEnrichmentCache.defaultURL) -> [Self] {
        [
            Self(id: .britain, url: URL(string: "https://epgshare01.online/epgshare01/epg_ripper_UK1.xml.gz")!,
                 cacheURL: cacheURL?.deletingLastPathComponent().appendingPathComponent("uk.json")),
            Self(id: .usPBS, url: URL(string: "https://epgshare01.online/epgshare01/epg_ripper_US_LOCALS1.xml.gz")!, cacheURL: cacheURL)
        ]
    }
}

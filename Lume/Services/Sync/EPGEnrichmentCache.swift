import Foundation

nonisolated enum EPGEnrichmentSettings {
    static let enabledKey = "lume.epgEnrichment.enabled"
    // Earlier builds stamped `checked` before publication. A new key makes
    // those installs publish their existing fresh cache once, without a fetch.
    static let checkedKey = "lume.epgEnrichment.publishedCheck"
    static let publicationPendingKey = "lume.epgEnrichment.publicationPending"
    // Only actual failures impose backoff. Older builds recorded all attempts,
    // including cancellations; intentionally do not reuse that preference.
    static let failedKey = "lume.epgEnrichment.failed"
    static let refreshInterval: TimeInterval = 24 * 3600
    static let retryInterval: TimeInterval = 3600

    static func isDue(defaults: UserDefaults = .standard, now: Date = Date(), feeds: [EPGEnrichmentFeed.Identifier] = EPGEnrichmentFeed.Identifier.allCases) -> Bool {
        guard defaults.bool(forKey: enabledKey) else { return false }
        return feeds.contains { feed in
            let checked = defaults.double(forKey: feed.checkedKey)
            let failed = defaults.double(forKey: feed.failedKey)
            let stale = checked <= 0 || now.timeIntervalSince1970 < checked || now.timeIntervalSince1970 - checked >= feed.refreshInterval
            let mayAttempt = failed <= 0 || now.timeIntervalSince1970 < failed || now.timeIntervalSince1970 - failed >= retryInterval
            return (stale || defaults.bool(forKey: publicationPendingKey)) && mayAttempt
        }
    }
}

/// Only selected public station metadata is cached, not the country guide or
/// provider credentials. Cache eviction is safe: the next pass refetches it.
nonisolated struct EPGEnrichmentCache: Codable {
    static let schemaVersion = 1
    static let maximumAge: TimeInterval = 48 * 3600
    static let maximumProgrammes = 10000

    var version = schemaVersion
    let url: String
    var checkedAt: Date
    let channelIDs: Set<String>
    let programmes: [ParsedProgramme]
    let lastModified: String?
    let entityTag: String?

    func isUsable(url: String, now: Date) -> Bool {
        version == Self.schemaVersion && self.url == url && checkedAt <= now && now.timeIntervalSince(checkedAt) < Self.maximumAge
            && !programmes.isEmpty && programmes.count <= Self.maximumProgrammes && programmes.contains { $0.end > now }
    }

    func isFresh(url: String, channelIDs: Set<String>, now: Date, refreshInterval: TimeInterval = EPGEnrichmentSettings.refreshInterval) -> Bool {
        isUsable(url: url, now: now) && channelIDs.isSubset(of: self.channelIDs)
            && now.timeIntervalSince(checkedAt) < refreshInterval
    }

    static var defaultURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LumeEPGEnrichment", isDirectory: true).appendingPathComponent("us-locals.json")
    }

    static func read(from url: URL?) -> EPGEnrichmentCache? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(to url: URL?) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

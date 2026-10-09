import Foundation

nonisolated enum EPGEnrichmentSettings {
    static let enabledKey = "lume.epgEnrichment.enabled"
    static let checkedKey = "lume.epgEnrichment.checked"
    static let attemptedKey = "lume.epgEnrichment.attempted"
    static let refreshInterval: TimeInterval = 24 * 3600
    static let retryInterval: TimeInterval = 3600

    static func isDue(defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard defaults.bool(forKey: enabledKey) else { return false }
        let checked = defaults.double(forKey: checkedKey)
        let attempted = defaults.double(forKey: attemptedKey)
        let stale = checked <= 0 || now.timeIntervalSince1970 < checked || now.timeIntervalSince1970 - checked >= refreshInterval
        let mayAttempt = attempted <= 0 || now.timeIntervalSince1970 < attempted || now.timeIntervalSince1970 - attempted >= retryInterval
        return stale && mayAttempt
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

    func isFresh(url: String, channelIDs: Set<String>, now: Date) -> Bool {
        isUsable(url: url, now: now) && channelIDs.isSubset(of: self.channelIDs)
            && now.timeIntervalSince(checkedAt) < EPGEnrichmentSettings.refreshInterval
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

import Foundation
@testable import Lume
import Testing

struct EPGEnrichmentCacheTests {
    @Test func `metadata scheduling is independent and failed attempts back off`() throws {
        let defaults = try #require(UserDefaults(suiteName: "EPGEnrichmentCacheTests-\(UUID())"))
        defer {
            for key in [EPGEnrichmentSettings.enabledKey, EPGEnrichmentSettings.checkedKey, EPGEnrichmentSettings.attemptedKey] {
                defaults.removeObject(forKey: key)
            }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, now: now))
        defaults.set(true, forKey: EPGEnrichmentSettings.enabledKey)
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now))
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentSettings.attemptedKey)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(60)))
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(3600)))
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentSettings.checkedKey)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(23 * 3600)))
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(24 * 3600)))
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(-1)))
    }

    @Test func `cache freshness requires matching feed selection schema horizon and age`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let programme = ParsedProgramme(
            channelId: "station", title: "Programme", subtitle: nil, description: "", categories: [], start: now, end: now.addingTimeInterval(3 * 86400)
        )
        var cache = EPGEnrichmentCache(url: "https://example.com/guide", checkedAt: now, channelIDs: ["station"], programmes: [programme], lastModified: nil, entityTag: nil)
        #expect(cache.isFresh(url: cache.url, channelIDs: ["station"], now: now))
        #expect(!cache.isFresh(url: cache.url, channelIDs: ["new station"], now: now))
        #expect(!cache.isFresh(url: "https://example.com/different", channelIDs: ["station"], now: now))
        #expect(!cache.isFresh(url: cache.url, channelIDs: ["station"], now: now.addingTimeInterval(25 * 3600)))
        #expect(cache.isUsable(url: cache.url, now: now.addingTimeInterval(25 * 3600)))
        #expect(!cache.isUsable(url: cache.url, now: now.addingTimeInterval(49 * 3600)))
        #expect(!cache.isUsable(url: cache.url, now: now.addingTimeInterval(-1)))
        cache.version = 0
        #expect(!cache.isUsable(url: cache.url, now: now))
    }
}

import Foundation
@testable import Lume
import Testing

struct EPGEnrichmentCacheTests {
    @Test func `expanded UK registry becomes due without waiting for the old selection cadence`() throws {
        let name = "EPGEnrichmentCacheTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        defaults.set(true, forKey: EPGEnrichmentSettings.enabledKey)
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentSettings.checkedKey + ".uk")
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentFeed.Identifier.usPBS.checkedKey)
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now))
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentFeed.Identifier.britain.checkedKey)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, now: now))
    }

    @Test func `metadata cache accommodates expanded selections but retains a hard programme limit`() {
        let now = Date()
        let programme = ParsedProgramme(channelId: "station", title: "Programme", subtitle: nil, description: "", categories: [], start: now, end: now.addingTimeInterval(3600))
        let cache = EPGEnrichmentCache(url: "guide", checkedAt: now, channelIDs: ["station"],
                                       programmes: Array(repeating: programme, count: 14000), lastModified: nil, entityTag: nil)
        #expect(cache.isUsable(url: cache.url, now: now))
        let oversized = EPGEnrichmentCache(url: cache.url, checkedAt: now, channelIDs: cache.channelIDs,
                                           programmes: Array(repeating: programme, count: EPGEnrichmentCache.maximumProgrammes + 1), lastModified: nil, entityTag: nil)
        #expect(!oversized.isUsable(url: cache.url, now: now))
    }

    @Test func `new country and independent country cadences are checked even with a fresh PBS publication`() throws {
        let name = "EPGEnrichmentCacheTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        defaults.set(true, forKey: EPGEnrichmentSettings.enabledKey)
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentFeed.Identifier.usPBS.checkedKey)
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now))
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentFeed.Identifier.britain.checkedKey)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(11 * 3600)))
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(12 * 3600)))
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(12 * 3600), feeds: [.usPBS]))
    }

    @Test func `unpublished fresh metadata stays due until committed`() throws {
        let name = "EPGEnrichmentCacheTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: EPGEnrichmentSettings.enabledKey)
        defaults.set(Date().timeIntervalSince1970, forKey: "lume.epgEnrichment.checked")
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, feeds: [.usPBS]))
        defaults.set(Date().timeIntervalSince1970, forKey: EPGEnrichmentSettings.checkedKey)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, feeds: [.usPBS]))
        defaults.set(true, forKey: EPGEnrichmentSettings.publicationPendingKey)
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, feeds: [.usPBS]))
        defaults.set(Date().timeIntervalSince1970, forKey: EPGEnrichmentSettings.failedKey)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, feeds: [.usPBS]))
    }

    @Test(arguments: [EPGEnrichmentReport.State.unavailable, .deferred])
    func `unavailable and backed off metadata are warnings`(_ state: EPGEnrichmentReport.State) {
        #expect(EPGEnrichmentReport(state: state).hasWarning)
    }

    @Test(arguments: [EPGEnrichmentReport.State.disabled, .unsupported, .downloaded, .unchanged, .cached, .interrupted])
    func `normal results and deliberate interruption are not failures`(_ state: EPGEnrichmentReport.State) {
        #expect(!EPGEnrichmentReport(state: state).hasWarning)
    }

    @Test func `metadata scheduling is independent and failed attempts back off`() throws {
        let defaults = try #require(UserDefaults(suiteName: "EPGEnrichmentCacheTests-\(UUID())"))
        defer {
            for key in [EPGEnrichmentSettings.enabledKey, EPGEnrichmentSettings.checkedKey, EPGEnrichmentSettings.failedKey] {
                defaults.removeObject(forKey: key)
            }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, now: now, feeds: [.usPBS]))
        defaults.set(true, forKey: EPGEnrichmentSettings.enabledKey)
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now, feeds: [.usPBS]))
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentSettings.failedKey)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(60), feeds: [.usPBS]))
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(3600), feeds: [.usPBS]))
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentSettings.checkedKey)
        #expect(!EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(23 * 3600), feeds: [.usPBS]))
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(24 * 3600), feeds: [.usPBS]))
        #expect(EPGEnrichmentSettings.isDue(defaults: defaults, now: now.addingTimeInterval(-1), feeds: [.usPBS]))
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

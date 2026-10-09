import Foundation
@testable import Lume
import SwiftData
import Testing

@Suite(.readsGlobalState)
@MainActor
struct EPGEnrichmentCategoriesTests {
    @Test func `only the two pilot categories default on and explicit choices override defaults`() {
        #expect(EPGEnrichmentCategories.defaultEnabled(name: "UK | Entertainment"))
        #expect(EPGEnrichmentCategories.defaultEnabled(name: "UK|Sky sports"))
        #expect(!EPGEnrichmentCategories.defaultEnabled(name: "UK | Kids"))
        #expect(!EPGEnrichmentCategories.defaultEnabled(name: "US | PBS"))
        #expect(!EPGEnrichmentCategories.isSelected(name: "UK | Entertainment", override: false))
        #expect(EPGEnrichmentCategories.isSelected(name: "US | PBS", override: true))
        #expect(!EPGEnrichmentCategories.isEligible(name: "UK | Entertainment", type: "live", hidden: true, override: true))
        #expect(!EPGEnrichmentCategories.isEligible(name: "UK | Entertainment", type: "vod", hidden: false, override: true))
    }

    @Test func `category checkpoint survives interruption and ignores category reordering`() throws {
        let schema = Schema([EPGListing.self, EPGSource.self, LiveStream.self, Category.self, Playlist.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let suite = "EPGCategoriesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: EPGEnrichmentSettings.enabledKey)
        let context = container.mainContext
        let category = Category(apiId: "105", name: "UK | Entertainment", parentId: 0, type: .live)
        context.insert(category)
        try context.save()
        let monitor = EPGEnrichmentSelectionMonitor(container: container, defaults: defaults) {}
        #expect(monitor.check(notify: false))
        monitor.published(monitor.fingerprint)
        category.customOrder = 2
        try context.save()
        #expect(!monitor.check(notify: false))
        category.epgEnrichmentEnabled = false
        try context.save()
        #expect(monitor.check(notify: false))
        // The old publication checkpoint must remain until new metadata commits.
        let restarted = EPGEnrichmentSelectionMonitor(container: container, defaults: defaults) {}
        #expect(restarted.check(notify: false))
        restarted.published(restarted.fingerprint)
        let published = EPGEnrichmentSelectionMonitor(container: container, defaults: defaults) {}
        #expect(!published.check(notify: false))
        defaults.set(false, forKey: EPGEnrichmentSettings.enabledKey)
        #expect(published.check(notify: false)) // global-off restoration is owed too
    }

    @Test func `uncategorized streams and unselected categories cannot be enhanced`() throws {
        let schema = Schema([EPGListing.self, EPGSource.self, LiveStream.self, Category.self, Playlist.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let category = Category(apiId: "105", name: "UK | Entertainment", parentId: 0, type: .live)
        context.insert(category)
        let stream = LiveStream(id: "bbc2", streamId: 1, name: "BBC TWO FHD", epgChannelId: "BBCTwo.uk")
        context.insert(stream)
        try context.save()
        #expect(try EPGEnrichmentScope.load(in: context).aliases(for: .britain).isEmpty)
        stream.categoryId = category.id
        try context.save()
        #expect(try EPGEnrichmentScope.load(in: context).aliases(for: .britain)["BBC.Two.HD.uk"] == ["BBCTwo.uk"])
        category.epgEnrichmentEnabled = false
        try context.save()
        #expect(try EPGEnrichmentScope.load(in: context).aliases(for: .britain).isEmpty)
        category.epgEnrichmentEnabled = true
        category.isHidden = true
        try context.save()
        #expect(try EPGEnrichmentScope.load(in: context).aliases(for: .britain).isEmpty)
    }
}

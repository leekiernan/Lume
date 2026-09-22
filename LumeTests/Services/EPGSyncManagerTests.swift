import Foundation
@testable import Lume
import SwiftData
import Testing

struct EPGSyncManagerTests {
    private func writeTempXMLTV(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPGSyncManagerTests-\(UUID().uuidString).xml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeOnDiskContainer() throws -> (ModelContainer, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPGPublicationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = OnDiskCatalogStore.catalogSchema
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appendingPathComponent("catalog.store"),
            cloudKitDatabase: .none
        )
        do {
            return try (ModelContainer(for: schema, configurations: configuration), directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func seedChannels(_ channelIDs: [String], in context: ModelContext) {
        for (index, channelID) in channelIDs.enumerated() {
            context.insert(LiveStream(
                id: "channel-\(index)",
                streamId: index,
                name: channelID,
                epgChannelId: channelID
            ))
        }
    }

    private func insertSource(
        named name: String,
        url: String,
        addedAt: Date = .distantPast,
        in context: ModelContext
    ) -> EPGSource {
        let source = EPGSource(name: name, url: url)
        source.addedAt = addedAt
        context.insert(source)
        return source
    }

    private func insertListing(
        id: String,
        channelID: String,
        title: String,
        sourceID: UUID? = nil,
        in context: ModelContext
    ) {
        context.insert(EPGListing(
            id: id,
            channelId: channelID,
            title: title,
            listingDescription: "Description",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600),
            sourceID: sourceID
        ))
    }

    @Test func `a valid empty guide retires the legacy aggregate snapshot`() async throws {
        let fileURL = try writeTempXMLTV("<?xml version=\"1.0\" encoding=\"UTF-8\"?><tv></tv>")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let container = try makeTestContainer()
        let setupContext = ModelContext(container)
        setupContext.insert(LiveStream(id: "news", streamId: 1, name: "News", epgChannelId: "news.1"))
        let source = EPGSource(name: "Guide", url: fileURL.absoluteString)
        setupContext.insert(source)
        // Simulates the aggregate guide format written before listings had a
        // source ID. A well-formed empty document is an authoritative empty
        // replacement, not a failed download, so the old aggregate must not
        // survive indefinitely.
        setupContext.insert(EPGListing(
            id: "legacy-news",
            channelId: "news.1",
            title: "Stale news",
            listingDescription: "Old guide",
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600)
        ))
        try setupContext.save()

        #expect(await EPGSyncManager(modelContainer: container).syncAllSources())

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<EPGListing>()).isEmpty)
        let refreshed = try #require(try context.fetch(FetchDescriptor<EPGSource>()).first)
        #expect(refreshed.committedGeneration == 1)
    }

    @Test func `a failed source retains its committed snapshot`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        seedChannels(["news.1"], in: context)
        let source = insertSource(
            named: "Unavailable guide",
            url: "file:///missing-\(UUID().uuidString).xml",
            in: context
        )
        insertListing(
            id: "old-news",
            channelID: "news.1",
            title: "Previous news",
            sourceID: source.id,
            in: context
        )
        try context.save()

        let didSync = await EPGSyncManager(modelContainer: container).syncAllSources()
        #expect(!didSync)

        let refreshed = ModelContext(container)
        let listings = try refreshed.fetch(FetchDescriptor<EPGListing>())
        #expect(listings.map(\.title) == ["Previous news"])
        let storedSource = try #require(try refreshed.fetch(FetchDescriptor<EPGSource>()).first)
        #expect(storedSource.committedGeneration == 0)
        #expect(storedSource.syncStatus == .error)
    }

    @Test func `a partial multi-source failure retains one snapshot while publishing another`() async throws {
        let sportXMLTV = """
        <tv>
          <programme start="20260611120000 +0000" stop="20260611130000 +0000" channel="sport.1">
            <title>Live sport</title>
          </programme>
        </tv>
        """
        let sportURL = try writeTempXMLTV(sportXMLTV)
        defer { try? FileManager.default.removeItem(at: sportURL) }

        let container = try makeTestContainer()
        let context = ModelContext(container)
        seedChannels(["news.1", "sport.1"], in: context)
        let failed = insertSource(
            named: "Unavailable guide",
            url: "file:///missing-\(UUID().uuidString).xml",
            in: context
        )
        _ = insertSource(
            named: "Sport guide",
            url: sportURL.absoluteString,
            addedAt: Date.distantPast.addingTimeInterval(1),
            in: context
        )
        insertListing(
            id: "old-news",
            channelID: "news.1",
            title: "Previous news",
            sourceID: failed.id,
            in: context
        )
        try context.save()

        let didSync = await EPGSyncManager(modelContainer: container).syncAllSources()
        #expect(!didSync)

        let refreshed = ModelContext(container)
        let listings = try refreshed.fetch(FetchDescriptor<EPGListing>())
        #expect(Set(listings.map(\.title)) == ["Previous news", "Live sport"])
        let sources = try refreshed.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.first(where: { $0.name == "Unavailable guide" })?.syncStatus == .error)
        #expect(sources.first(where: { $0.name == "Sport guide" })?.committedGeneration == 1)
    }

    @Test func `a superseded source retires its old overlapping snapshot`() async throws {
        let guideURL = try writeTempXMLTV("""
        <tv>
          <programme start="20260611120000 +0000" stop="20260611130000 +0000" channel="news.1">
            <title>Primary guide</title>
          </programme>
        </tv>
        """)
        defer { try? FileManager.default.removeItem(at: guideURL) }

        let container = try makeTestContainer()
        let context = ModelContext(container)
        seedChannels(["news.1"], in: context)
        _ = insertSource(named: "Primary", url: guideURL.absoluteString, in: context)
        let secondary = insertSource(
            named: "Secondary",
            url: "file:///missing-\(UUID().uuidString).xml",
            addedAt: Date.distantPast.addingTimeInterval(1),
            in: context
        )
        insertListing(
            id: "old-secondary-news",
            channelID: "news.1",
            title: "Overlapping old guide",
            sourceID: secondary.id,
            in: context
        )
        try context.save()

        #expect(await EPGSyncManager(modelContainer: container).syncAllSources())

        let refreshed = ModelContext(container)
        let listings = try refreshed.fetch(FetchDescriptor<EPGListing>())
        #expect(listings.map(\.title) == ["Primary guide"])
        let sources = try refreshed.fetch(FetchDescriptor<EPGSource>())
        #expect(sources.first(where: { $0.name == "Secondary" })?.committedGeneration == 1)
    }

    @Test func `duplicate programmes collapse deterministically before publication`() async throws {
        let duplicatedXMLTV = """
        <tv>
          <programme start="20260611120000 +0000" stop="20260611130000 +0000" channel="news.1">
            <title>Zebra bulletin</title>
          </programme>
          <programme start="20260611120000 +0000" stop="20260611130000 +0000" channel="news.1">
            <title>Alpha bulletin</title>
          </programme>
        </tv>
        """
        let guideURL = try writeTempXMLTV(duplicatedXMLTV)
        defer { try? FileManager.default.removeItem(at: guideURL) }

        let container = try makeTestContainer()
        let context = ModelContext(container)
        seedChannels(["news.1"], in: context)
        _ = insertSource(named: "Guide", url: guideURL.absoluteString, in: context)
        try context.save()

        #expect(await EPGSyncManager(modelContainer: container).syncAllSources())

        let listings = try ModelContext(container).fetch(FetchDescriptor<EPGListing>())
        #expect(listings.count == 1)
        #expect(listings.first?.title == "Alpha bulletin")
    }

    @Test func `repeated publication updates matching IDs and removes only stale programmes`() async throws {
        let guideURL = try writeTempXMLTV("""
        <tv>
          <programme start="20260611120000 +0000" stop="20260611130000 +0000" channel="news.1">
            <title>Original bulletin</title>
          </programme>
          <programme start="20260611130000 +0000" stop="20260611140000 +0000" channel="news.1">
            <title>Departing bulletin</title>
          </programme>
        </tv>
        """)
        defer { try? FileManager.default.removeItem(at: guideURL) }

        // Use SQLite here: the original failure was a DefaultStore identity
        // remap during save, which an in-memory container need not reproduce.
        let (container, directory) = try makeOnDiskContainer()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setupContext = ModelContext(container)
        seedChannels(["news.1"], in: setupContext)
        let source = insertSource(named: "Guide", url: guideURL.absoluteString, in: setupContext)
        let sourceID = source.id
        try setupContext.save()

        let manager = EPGSyncManager(modelContainer: container)
        #expect(await manager.syncAllSources())
        let originalRows = try ModelContext(container).fetch(FetchDescriptor<EPGListing>())
        let retained = try #require(originalRows.first(where: { $0.title == "Original bulletin" }))
        let retainedID = retained.id
        let retainedPersistentID = retained.persistentModelID
        #expect(originalRows.count == 2)

        try """
        <tv>
          <programme start="20260611120000 +0000" stop="20260611133000 +0000" channel="news.1">
            <title>Updated bulletin</title>
          </programme>
          <programme start="20260611140000 +0000" stop="20260611150000 +0000" channel="news.1">
            <title>New bulletin</title>
          </programme>
        </tv>
        """.write(to: guideURL, atomically: true, encoding: .utf8)

        #expect(await manager.syncAllSources())
        #expect(await manager.syncAllSources())

        let refreshed = ModelContext(container)
        let rows = try refreshed.fetch(FetchDescriptor<EPGListing>())
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.title)) == ["Updated bulletin", "New bulletin"])
        #expect(rows.first(where: { $0.title == "Updated bulletin" })?.id == retainedID)
        #expect(rows.first(where: { $0.title == "Updated bulletin" })?.persistentModelID == retainedPersistentID)
        #expect(rows.allSatisfy { $0.sourceID == sourceID })
        let storedSource = try #require(try refreshed.fetch(FetchDescriptor<EPGSource>()).first)
        #expect(storedSource.committedGeneration == 3)
    }

    @Test func `a suspicious empty mapping retains the prior source snapshot`() async throws {
        let unrelatedXMLTV = """
        <tv>
          <programme start="20260611120000 +0000" stop="20260611130000 +0000" channel="other.1">
            <title>Other guide</title>
          </programme>
        </tv>
        """
        let guideURL = try writeTempXMLTV(unrelatedXMLTV)
        defer { try? FileManager.default.removeItem(at: guideURL) }

        let container = try makeTestContainer()
        let context = ModelContext(container)
        seedChannels(["news.1"], in: context)
        let source = insertSource(named: "Guide", url: guideURL.absoluteString, in: context)
        insertListing(
            id: "old-news",
            channelID: "news.1",
            title: "Previous news",
            sourceID: source.id,
            in: context
        )
        try context.save()

        let didSync = await EPGSyncManager(modelContainer: container).syncAllSources()
        #expect(!didSync)

        let refreshed = ModelContext(container)
        #expect(try refreshed.fetch(FetchDescriptor<EPGListing>()).map(\.title) == ["Previous news"])
        let storedSource = try #require(try refreshed.fetch(FetchDescriptor<EPGSource>()).first)
        #expect(storedSource.syncStatus == .error)
        #expect(storedSource.committedGeneration == 0)
    }

    @Test func `an XMLTV document with only unusable programmes retains the snapshot`() async throws {
        let guideURL = try writeTempXMLTV("""
        <tv>
          <programme channel="news.1"><title>Missing dates</title></programme>
        </tv>
        """)
        defer { try? FileManager.default.removeItem(at: guideURL) }

        let container = try makeTestContainer()
        let context = ModelContext(container)
        seedChannels(["news.1"], in: context)
        let source = insertSource(named: "Guide", url: guideURL.absoluteString, in: context)
        insertListing(id: "old-news", channelID: "news.1", title: "Previous news", sourceID: source.id, in: context)
        try context.save()

        let didSync = await EPGSyncManager(modelContainer: container).syncAllSources()
        #expect(!didSync)

        let refreshed = ModelContext(container)
        #expect(try refreshed.fetch(FetchDescriptor<EPGListing>()).map(\.title) == ["Previous news"])
        let storedSource = try #require(try refreshed.fetch(FetchDescriptor<EPGSource>()).first)
        #expect(storedSource.committedGeneration == 0)
    }

    @Test func `interrupted source status is recovered without touching listings`() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let source = insertSource(named: "Guide", url: "file:///guide.xml", in: context)
        source.syncStatus = .syncing
        insertListing(id: "existing", channelID: "news.1", title: "Existing", sourceID: source.id, in: context)
        try context.save()

        EPGSyncManager.recoverInterruptedSyncs(in: context)

        #expect(source.syncStatus == .idle)
        #expect(try context.fetch(FetchDescriptor<EPGListing>()).map(\.title) == ["Existing"])
    }
}

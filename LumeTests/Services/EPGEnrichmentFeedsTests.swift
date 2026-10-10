import Foundation
@testable import Lume
import SwiftData
import Synchronization
import Testing

@Suite(.readsGlobalState)
@MainActor
struct EPGEnrichmentFeedsTests {
    @MainActor
    private final class Fixture {
        let container: ModelContainer
        let defaults: UserDefaults
        let suite = "EPGEnrichmentFeedsTests-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EPGEnrichmentFeedsTests-\(UUID())")
        let feeds: [EPGEnrichmentFeed]

        init(url: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: EPGEnrichmentSettings.enabledKey)
            let directory = directory
            feeds = [.britain, .usPBS].map { .init(id: $0, url: url.deletingLastPathComponent().appendingPathComponent($0.rawValue),
                                                   cacheURL: directory.appendingPathComponent("\($0.rawValue).json")) }
            let schema = Schema([EPGListing.self, EPGSource.self, LiveStream.self, Category.self, Playlist.self])
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: directory.appendingPathComponent("catalog.store"), cloudKitDatabase: .none))
            let context = container.mainContext
            let source = EPGSource(name: "Provider", url: url.absoluteString)
            context.insert(source)
            let category = Category(apiId: "selected", name: "Selected", parentId: 0, type: .live)
            category.epgEnrichmentEnabled = true
            context.insert(category)
            for (id, name) in [("BBCTwo.uk", "BBC TWO FHD"), ("PBSKQED.us", "US PBS (KQED) San Francisco")] {
                context.insert(LiveStream(id: id, streamId: 1, name: name, epgChannelId: id, categoryId: category.id))
                context.insert(EPGListing(id: id, channelId: id, title: "News", listingDescription: "Provider",
                                          start: Self.start, end: Self.start.addingTimeInterval(3600), sourceID: source.id))
            }
            try context.save()
        }

        nonisolated static var start: Date {
            Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
        }

        nonisolated static func document(british: Bool) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMddHHmmss Z"
            return """
            <tv><programme channel="\(british ? "BBC.Two.HD.uk" : "KQED-DT.us_locals1")" start="\(formatter.string(from: start))" stop="\(formatter.string(from: start.addingTimeInterval(3600)))">
            <title>News</title><icon src="https://example.test/\(british ? "uk" : "us").jpg"/></programme></tv>
            """
        }

        func sync() -> EPGEnrichmentSync {
            EPGEnrichmentSync(writeCoordinator: LocalStoreWriteCoordinator(), defaults: defaults, feeds: feeds)
        }

        func rows() throws -> [EPGListing] {
            try ModelContext(container).fetch(FetchDescriptor<EPGListing>())
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func `both countries stay enriched when only UK becomes due and disabling restores both`() async throws {
        let requests = Mutex<[Bool]>([])
        let server = try GuideHTTPServer { request in
            let british = request.hasPrefix("GET /uk")
            requests.withLock { $0.append(british) }
            return .init(body: Fixture.document(british: british))
        }
        defer { server.stop() }
        let fixture = try await Fixture(url: server.start())
        defer { fixture.cleanup() }
        let sync = fixture.sync()
        let first = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(first.feeds.map(\.feedID) == [.britain, .usPBS])
        #expect(first.matchedProgrammes == 2)
        #expect(first.changedProgrammes == 2)
        #expect(requests.withLock { $0 } == [true, false])
        let british = fixture.feeds[0]
        var cache = try #require(EPGEnrichmentCache.read(from: british.cacheURL))
        cache.checkedAt = Date().addingTimeInterval(-13 * 3600)
        try cache.write(to: british.cacheURL)
        fixture.defaults.set(cache.checkedAt.timeIntervalSince1970, forKey: british.id.checkedKey)
        #expect(EPGEnrichmentSettings.isDue(defaults: fixture.defaults))
        let second = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(second.feeds.map(\.state) == [.downloaded, .cached])
        #expect(second.changedProgrammes == 0)
        #expect(try fixture.rows().allSatisfy { $0.artworkURL != nil })
        #expect(requests.withLock { $0 } == [true, false, true])
        #expect(!EPGEnrichmentSettings.isDue(defaults: fixture.defaults))
        let disabled = try await sync.sync(container: fixture.container, enabled: false, fence: .live)
        #expect(disabled.state == .disabled)
        #expect(disabled.changedProgrammes == 2)
        #expect(try fixture.rows().allSatisfy { $0.artworkURL == nil && $0.enrichmentBaseline == nil })
        #expect(requests.withLock { $0.count } == 3)
    }

    @Test func `one country failing does not block another or share its backoff`() async throws {
        let requests = Mutex<[Bool]>([])
        let server = try GuideHTTPServer { request in
            let british = request.hasPrefix("GET /uk")
            requests.withLock { $0.append(british) }
            return .init(body: british ? "<tv>invalid" : Fixture.document(british: false))
        }
        defer { server.stop() }
        let fixture = try await Fixture(url: server.start())
        defer { fixture.cleanup() }
        let sync = fixture.sync()
        let first = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(first.hasWarning)
        #expect(first.feeds.map(\.state) == [.unavailable, .downloaded])
        #expect(first.changedProgrammes == 1)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentFeed.Identifier.britain.checkedKey) == 0)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentFeed.Identifier.usPBS.checkedKey) > 0)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentFeed.Identifier.usPBS.failedKey) == 0)
        #expect(!EPGEnrichmentSettings.isDue(defaults: fixture.defaults))
        let second = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(second.feeds.map(\.state) == [.deferred, .cached])
        #expect(second.changedProgrammes == 0)
        #expect(requests.withLock { $0 } == [true, false])
        #expect(try fixture.rows().first { $0.channelId == "PBSKQED.us" }?.artworkURL != nil)
    }

    @Test func `cancelling the second country retains the first cache but does not publish half a guide`() async throws {
        let requests = Mutex<[Bool]>([])
        let server = try GuideHTTPServer { request in
            let british = request.hasPrefix("GET /uk")
            let count = requests.withLock { $0.append(british); return $0.count }
            return .init(body: Fixture.document(british: british), delay: count == 2 ? 2 : 0)
        }
        defer { server.stop() }
        let fixture = try await Fixture(url: server.start())
        defer { fixture.cleanup() }
        let sync = fixture.sync()
        let task = Task { try await sync.sync(container: fixture.container, enabled: true, fence: .live) }
        for _ in 0 ..< 200 {
            if requests.withLock({ $0.count }) >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(requests.withLock { $0.count } == 2)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(EPGEnrichmentCache.read(from: fixture.feeds[0].cacheURL) != nil)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentFeed.Identifier.britain.checkedKey) == 0)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentFeed.Identifier.usPBS.failedKey) == 0)
        #expect(fixture.defaults.bool(forKey: EPGEnrichmentSettings.publicationPendingKey))
        #expect(try fixture.rows().allSatisfy { $0.artworkURL == nil })
        let retry = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(retry.feeds.map(\.state) == [.cached, .downloaded])
        #expect(retry.changedProgrammes == 2)
        #expect(requests.withLock { $0 } == [true, false, false])
    }

    @Test func `an unsupported country does not download or stay perpetually due`() async throws {
        let requests = Mutex(0)
        let server = try GuideHTTPServer { _ in requests.withLock { $0 += 1 }; return .init(body: Fixture.document(british: false)) }
        defer { server.stop() }
        let fixture = try await Fixture(url: server.start())
        defer { fixture.cleanup() }
        let context = ModelContext(fixture.container)
        let british = try #require(try context.fetch(FetchDescriptor<LiveStream>()).first { $0.epgChannelId == "BBCTwo.uk" })
        british.isHidden = true
        try context.save()
        let report = try await fixture.sync().sync(container: fixture.container, enabled: true, fence: .live)
        #expect(report.feeds.map(\.state) == [.unsupported, .downloaded])
        #expect(!report.hasWarning)
        #expect(requests.withLock { $0 } == 1)
        #expect(!EPGEnrichmentSettings.isDue(defaults: fixture.defaults))
    }

    @Test func `turning off category enhancement restores provider metadata without another fetch`() async throws {
        let requests = Mutex(0)
        let server = try GuideHTTPServer { request in
            requests.withLock { $0 += 1 }
            return .init(body: Fixture.document(british: request.hasPrefix("GET /uk")))
        }
        defer { server.stop() }
        let fixture = try await Fixture(url: server.start())
        defer { fixture.cleanup() }
        let sync = fixture.sync()
        try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(try fixture.rows().allSatisfy { $0.artworkURL != nil })
        let context = ModelContext(fixture.container)
        let category = try #require(try context.fetch(FetchDescriptor<Lume.Category>()).first)
        category.epgEnrichmentEnabled = false
        try context.save()
        let report = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(report.changedProgrammes == 2)
        #expect(try fixture.rows().allSatisfy { $0.artworkURL == nil && $0.enrichmentBaseline == nil })
        #expect(requests.withLock { $0 } == 2)
        category.epgEnrichmentEnabled = true
        try context.save()
        let restored = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(restored.changedProgrammes == 2)
        #expect(requests.withLock { $0 } == 2)
    }

    @Test func `expanding the selected stations refetches a fresh cache without old validators`() async throws {
        let requests = Mutex<[String]>([])
        let server = try GuideHTTPServer { request in
            requests.withLock { $0.append(request) }
            let british = request.hasPrefix("GET /uk")
            var document = Fixture.document(british: british)
            if british {
                let extra = Fixture.document(british: true).replacingOccurrences(of: "BBC.Two.HD.uk", with: "ITV2.HD.uk")
                document = document.replacingOccurrences(of: "</tv>", with: extra.replacingOccurrences(of: "<tv>", with: ""))
            }
            return .init(headers: ["Last-Modified": "Thu, 08 Oct 2026 12:00:00 GMT"], body: document)
        }
        defer { server.stop() }
        let fixture = try await Fixture(url: server.start())
        defer { fixture.cleanup() }
        let sync = fixture.sync()
        try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        let context = ModelContext(fixture.container)
        let row = try #require(try context.fetch(FetchDescriptor<EPGListing>()).first)
        let category = try #require(try context.fetch(FetchDescriptor<Lume.Category>()).first)
        context.insert(LiveStream(id: "ITV2", streamId: 2, name: "ITV 2 FHD", epgChannelId: "ITV2.uk", categoryId: category.id))
        context.insert(EPGListing(id: "ITV2", channelId: "ITV2.uk", title: row.title, listingDescription: row.listingDescription,
                                  start: row.start, end: row.end, sourceID: row.sourceID))
        try context.save()
        let report = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(report.feeds.map(\.state) == [.downloaded, .cached])
        #expect(report.feeds.first?.verifiedStations == 2)
        #expect(report.changedProgrammes == 1)
        #expect(requests.withLock { $0.count } == 3)
        #expect(requests.withLock { $0.last?.lowercased().contains("if-modified-since:") } == false)
        #expect(try fixture.rows().first { $0.channelId == "ITV2.uk" }?.artworkURL != nil)
    }

    @Test func `publication enriches multiple provider IDs and hiding one restores only that variant`() async throws {
        let server = try GuideHTTPServer { request in
            let document = Fixture.document(british: request.hasPrefix("GET /uk"))
                .replacingOccurrences(of: "BBC.Two.HD.uk", with: "SkySp.F1.HD.uk")
            return .init(body: document)
        }
        defer { server.stop() }
        let fixture = try await Fixture(url: server.start())
        defer { fixture.cleanup() }
        let context = ModelContext(fixture.container)
        let original = try #require(try context.fetch(FetchDescriptor<LiveStream>()).first { $0.epgChannelId == "BBCTwo.uk" })
        original.name = "Sky Sports F1 FHD"
        original.epgChannelId = "SkySportsF1.uk"
        let listing = try #require(try context.fetch(FetchDescriptor<EPGListing>()).first { $0.channelId == "BBCTwo.uk" })
        listing.channelId = "SkySportsF1.uk"
        context.insert(LiveStream(id: "F1-HD", streamId: 2, name: "Sky Sports F1 HD", epgChannelId: "skysportsf1.uk", categoryId: original.categoryId))
        context.insert(EPGListing(id: "F1-HD", channelId: "skysportsf1.uk", title: listing.title, listingDescription: listing.listingDescription,
                                  start: listing.start, end: listing.end, sourceID: listing.sourceID))
        try context.save()
        let sync = fixture.sync()
        let first = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(first.feeds.first?.verifiedStations == 1)
        #expect(first.feeds.first?.matchedProgrammes == 2)
        #expect(first.changedProgrammes == 3)
        original.isHidden = true
        try context.save()
        let second = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(second.feeds.first?.state == .cached)
        #expect(second.feeds.first?.matchedProgrammes == 1)
        #expect(second.changedProgrammes == 1)
        let rows = try fixture.rows()
        #expect(rows.first { $0.channelId == "SkySportsF1.uk" }?.artworkURL == nil)
        #expect(rows.first { $0.channelId == "skysportsf1.uk" }?.artworkURL != nil)
        #expect(rows.first { $0.channelId == "PBSKQED.us" }?.artworkURL != nil)
    }
}

import Foundation
@testable import Lume
import SwiftData
import Synchronization
import Testing

@Suite(.readsGlobalState)
@MainActor
struct EPGEnrichmentFeedsTests {
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
            for (id, name) in [("BBCTwo.uk", "BBC TWO FHD"), ("PBSKQED.us", "US PBS (KQED) San Francisco")] {
                context.insert(LiveStream(id: id, streamId: 1, name: name, epgChannelId: id))
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
}

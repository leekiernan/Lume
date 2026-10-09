import Foundation
@testable import Lume
import SwiftData
import Synchronization
import Testing

@Suite(.readsGlobalState)
@MainActor
struct EPGEnrichmentSyncTests {
    private nonisolated static let modified = "Thu, 08 Oct 2026 12:00:00 GMT"

    private final class Fixture {
        let container: ModelContainer
        let defaults: UserDefaults
        let directory: URL
        let cacheURL: URL
        let start: Date
        let end: Date

        init(providerURL: URL) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("EPGEnrichmentTests-\(UUID())", isDirectory: true)
            cacheURL = directory.appendingPathComponent("cache.json")
            let schema = Schema([EPGListing.self, EPGSource.self, LiveStream.self, Category.self, Playlist.self])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: directory.appendingPathComponent("catalog.store"), cloudKitDatabase: .none))
            defaults = try #require(UserDefaults(suiteName: "EPGEnrichmentTests-\(UUID())"))
            defaults.set(true, forKey: EPGEnrichmentSettings.enabledKey)
            start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
            end = start.addingTimeInterval(3600)
            container.mainContext.insert(EPGSource(name: "Provider", url: providerURL.absoluteString))
            let category = Category(apiId: "fixture", name: "PBS", parentId: 0, type: .live)
            category.epgEnrichmentEnabled = true
            container.mainContext.insert(category)
            container.mainContext.insert(LiveStream(id: "pbs", streamId: 1, name: "US PBS (KQED) San Francisco", epgChannelId: "PBSKQED.us", categoryId: category.id))
            try container.mainContext.save()
        }

        func cleanup() {
            for key in [
                EPGEnrichmentSettings.enabledKey, EPGEnrichmentSettings.checkedKey, EPGEnrichmentSettings.failedKey,
                EPGEnrichmentSettings.publicationPendingKey, "lume.epgEnrichment.attempted"
            ] {
                defaults.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        func supplement(url: URL, coordinator: LocalStoreWriteCoordinator) -> EPGEnrichmentSync {
            EPGEnrichmentSync(writeCoordinator: coordinator, cacheURL: cacheURL, defaults: defaults, feedURL: url)
        }

        func manager(externalURL: URL) -> EPGSyncManager {
            let coordinator = LocalStoreWriteCoordinator()
            return EPGSyncManager(modelContainer: container, writeCoordinator: coordinator, enrichment: supplement(url: externalURL, coordinator: coordinator))
        }

        func row() throws -> EPGListing {
            try #require(try ModelContext(container).fetch(FetchDescriptor<EPGListing>()).first)
        }

        func generation() throws -> UInt64 {
            try #require(try ModelContext(container).fetch(FetchDescriptor<EPGSource>()).first).committedGeneration
        }

        nonisolated static func document(channel: String, title: String = "Secrets of the Dead", artwork: String? = nil) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMddHHmmss Z"
            let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3600) * 3600)
            let end = start.addingTimeInterval(3600)
            return """
            <tv><programme start="\(formatter.string(from: start))" stop="\(formatter.string(from: end))" channel="\(channel)">
            <title>\(title)</title><desc>Original description</desc>\(artwork.map { "<icon src=\"\($0)\"/><category>Documentary</category><sub-title>Episode</sub-title>" } ?? "")
            </programme></tv>
            """
        }
    }

    @Test func `provider 304 reuses daily metadata cache and disabling restores the raw guide`() async throws {
        let requests = Mutex<[String]>([])
        let server = try GuideHTTPServer { raw in
            requests.withLock { $0.append(raw) }
            if raw.hasPrefix("GET /metadata") {
                return .init(headers: ["Last-Modified": Self.modified], body: Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/art.jpg"))
            }
            if raw.lowercased().contains("if-modified-since:") { return .init(status: 304) }
            return .init(headers: ["Last-Modified": Self.modified], body: Fixture.document(channel: "PBSKQED.us"))
        }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let manager = fixture.manager(externalURL: url.deletingLastPathComponent().appendingPathComponent("metadata"))
        #expect(await manager.syncAllSources(enrichProgrammes: true) == .succeeded)
        let downloaded = try #require(await manager.enrichmentReport)
        #expect(downloaded.state == .downloaded)
        #expect(downloaded.verifiedStations == 1)
        #expect(downloaded.cachedProgrammes == 1)
        #expect(downloaded.matchedProgrammes == 1)
        #expect(downloaded.changedProgrammes == 1)
        let identity = try fixture.row().persistentModelID
        #expect(try fixture.row().artworkURL == "https://example.com/art.jpg")
        #expect(try fixture.generation() == 2)
        #expect(await manager.syncAllSources(enrichProgrammes: true) == .succeeded)
        #expect(await manager.enrichmentReport?.state == .cached)
        #expect(await manager.enrichmentReport?.matchedProgrammes == 1)
        #expect(await manager.enrichmentReport?.changedProgrammes == 0)
        #expect(try fixture.generation() == 2)
        #expect(try fixture.row().persistentModelID == identity)
        #expect(await manager.syncAllSources(enrichProgrammes: false) == .succeeded)
        #expect(await manager.enrichmentReport?.state == .disabled)
        #expect(try fixture.row().artworkURL == nil)
        #expect(try fixture.row().subtitle == nil)
        #expect(try fixture.row().enrichmentBaseline == nil)
        #expect(try fixture.generation() == 3)
        #expect(requests.withLock { $0.count(where: { $0.hasPrefix("GET /metadata") }) } == 1)
    }

    @Test func `provider changes cannot inherit metadata from the previous programme`() async throws {
        let replacement = Mutex(false)
        let server = try GuideHTTPServer { raw in
            if raw.hasPrefix("GET /metadata") { return .init(body: Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/art.jpg")) }
            return .init(body: Fixture.document(channel: "PBSKQED.us", title: replacement.withLock { $0 } ? "Different Programme" : "Secrets of the Dead"))
        }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let manager = fixture.manager(externalURL: url.deletingLastPathComponent().appendingPathComponent("metadata"))
        #expect(await manager.syncAllSources(enrichProgrammes: true) == .succeeded)
        #expect(try fixture.row().artworkURL != nil)
        replacement.withLock { $0 = true }
        #expect(await manager.syncAllSources(enrichProgrammes: true) == .succeeded)
        #expect(try fixture.row().title == "Different Programme")
        #expect(try fixture.row().artworkURL == nil)
        #expect(try fixture.row().enrichmentBaseline == nil)
    }

    @Test func `invalid external documents keep the provider usable and persist retry backoff`() async throws {
        let downloads = Mutex(0)
        let available = Mutex(false)
        let server = try GuideHTTPServer { raw in
            if raw.hasPrefix("GET /metadata") {
                downloads.withLock { $0 += 1 }
                return .init(body: available.withLock { $0 } ? Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/art.jpg") : "<tv><programme")
            }
            return .init(body: Fixture.document(channel: "PBSKQED.us"))
        }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let external = url.deletingLastPathComponent().appendingPathComponent("metadata")
        for state in [EPGEnrichmentReport.State.unavailable, .deferred] {
            let manager = fixture.manager(externalURL: external)
            #expect(await manager.syncAllSources(enrichProgrammes: true) == .succeededWithWarnings)
            let report = try #require(await manager.enrichmentReport)
            #expect(report.state == state)
            #expect(report.retryAt != nil)
            #expect(report.checkedAt == nil)
            #expect(report.cachedProgrammes == 0)
        }
        #expect(downloads.withLock { $0 } == 1)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentSettings.checkedKey) == 0)
        #expect(try fixture.row().title == "Secrets of the Dead")
        #expect(try fixture.row().artworkURL == nil)
        available.withLock { $0 = true }
        fixture.defaults.set(Date().addingTimeInterval(-3601).timeIntervalSince1970, forKey: EPGEnrichmentSettings.failedKey)
        let recovered = fixture.manager(externalURL: external)
        #expect(await recovered.syncAllSources(enrichProgrammes: true) == .succeeded)
        #expect(downloads.withLock { $0 } == 2)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentSettings.failedKey) == 0)
        #expect(await recovered.enrichmentReport?.state == .downloaded)
        #expect(try fixture.row().artworkURL != nil)
    }

    @Test(arguments: [true, false]) func `hidden channels and disabled categories never request external metadata`(hideChannel: Bool) async throws {
        let requests = Mutex(0)
        let server = try GuideHTTPServer { _ in requests.withLock { $0 += 1 }; return .init() }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let context = ModelContext(fixture.container)
        let stream = try #require(try context.fetch(FetchDescriptor<LiveStream>()).first)
        let category = Category(apiId: "pbs", name: "PBS", parentId: 0, type: .live)
        category.epgEnrichmentEnabled = true
        category.isHidden = !hideChannel
        stream.isHidden = hideChannel
        stream.categoryId = category.id
        context.insert(category)
        try context.save()
        let report = try await fixture.supplement(url: url, coordinator: LocalStoreWriteCoordinator()).sync(container: fixture.container, enabled: true, fence: .live)
        #expect(report.state == .unsupported)
        #expect(requests.withLock { $0 } == 0)
    }

    @Test func `hidden conflicting identities remain unsafe aliases`() async throws {
        let requests = Mutex(0)
        let server = try GuideHTTPServer { _ in requests.withLock { $0 += 1 }; return .init() }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let context = ModelContext(fixture.container)
        let conflicting = LiveStream(id: "conflict", streamId: 2, name: "Unverified station", epgChannelId: "PBSKQED.us")
        conflicting.isHidden = true
        context.insert(conflicting)
        try context.save()
        let report = try await fixture.supplement(url: url, coordinator: LocalStoreWriteCoordinator()).sync(container: fixture.container, enabled: true, fence: .live)
        #expect(report.state == .unsupported)
        #expect(requests.withLock { $0 } == 0)
    }

    @Test func `unsupported catalog never requests external metadata`() async throws {
        let requests = Mutex(0)
        let server = try GuideHTTPServer { _ in requests.withLock { $0 += 1 }; return .init() }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let context = ModelContext(fixture.container)
        try #require(try context.fetch(FetchDescriptor<LiveStream>()).first).name = "Unverified PBS station"
        try context.save()
        let report = try await fixture.supplement(url: url, coordinator: LocalStoreWriteCoordinator()).sync(container: fixture.container, enabled: true, fence: .live)
        #expect(report.state == .unsupported)
        #expect(!report.hasWarning)
        #expect(requests.withLock { $0 } == 0)
    }

    @Test func `superseded publication retries from cache without another download`() async throws {
        let downloads = Mutex(0)
        let server = try GuideHTTPServer { _ in
            downloads.withLock { $0 += 1 }
            return .init(body: Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/art.jpg"))
        }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let context = ModelContext(fixture.container)
        let sourceID = try #require(try context.fetch(FetchDescriptor<EPGSource>()).first).id
        context.insert(EPGListing(id: "current", channelId: "PBSKQED.us", title: "Secrets of the Dead", listingDescription: "Provider", start: fixture.start, end: fixture.end, sourceID: sourceID))
        try context.save()
        let reject = Mutex(true)
        let live = Fence.live
        var changed = live
        changed.profile = UUID()
        let stale = changed
        let coordinator = LocalStoreWriteCoordinator(currentFence: { reject.withLock { $0 } ? stale : live })
        let sync = fixture.supplement(url: url, coordinator: coordinator)
        await #expect(throws: LocalStoreWriteError.superseded) {
            try await sync.sync(container: fixture.container, enabled: true, fence: live)
        }
        #expect(EPGEnrichmentCache.read(from: fixture.cacheURL) != nil)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentSettings.checkedKey) == 0)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentSettings.failedKey) == 0)
        #expect(EPGEnrichmentSettings.isDue(defaults: fixture.defaults))
        #expect(try fixture.row().artworkURL == nil)
        reject.withLock { $0 = false }
        let report = try await sync.sync(container: fixture.container, enabled: true, fence: live)
        #expect(report.state == .cached)
        #expect(report.changedProgrammes == 1)
        #expect(try fixture.row().artworkURL != nil)
        #expect(!EPGEnrichmentSettings.isDue(defaults: fixture.defaults, feeds: [.usPBS]))
        #expect(!fixture.defaults.bool(forKey: EPGEnrichmentSettings.publicationPendingKey))
        #expect(downloads.withLock { $0 } == 1)
    }

    @Test func `new cache metadata is applied on a provider 304 without changing its schedule`() async throws {
        let server = try GuideHTTPServer { raw in
            if raw.hasPrefix("GET /metadata") { return .init(body: Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/first.jpg")) }
            if raw.lowercased().contains("if-modified-since:") { return .init(status: 304) }
            return .init(headers: ["Last-Modified": Self.modified], body: Fixture.document(channel: "PBSKQED.us"))
        }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let manager = fixture.manager(externalURL: url.deletingLastPathComponent().appendingPathComponent("metadata"))
        #expect(await manager.syncAllSources(enrichProgrammes: true) == .succeeded)
        let previous = try #require(EPGEnrichmentCache.read(from: fixture.cacheURL))
        var programmes = previous.programmes
        programmes[0].artworkURL = "https://example.com/second.jpg"
        try EPGEnrichmentCache(
            url: previous.url, checkedAt: Date(), channelIDs: previous.channelIDs, programmes: programmes, lastModified: nil, entityTag: nil
        ).write(to: fixture.cacheURL)
        #expect(await manager.syncAllSources(enrichProgrammes: true) == .succeeded)
        #expect(try fixture.generation() == 3)
        #expect(try fixture.row().artworkURL == "https://example.com/second.jpg")
        #expect(try fixture.row().start == fixture.start)
        #expect(try fixture.row().end == fixture.end)
        #expect(try fixture.row().listingDescription == "Original description")
    }

    @Test func `a failed daily refresh retains recent metadata but expires it after 48 hours`() async throws {
        let failed = Mutex(false)
        let server = try GuideHTTPServer { _ in
            if failed.withLock({ $0 }) { return .init(status: 503) }
            return .init(headers: ["Last-Modified": Self.modified], body: Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/art.jpg"))
        }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let context = ModelContext(fixture.container)
        let sourceID = try #require(try context.fetch(FetchDescriptor<EPGSource>()).first).id
        context.insert(EPGListing(
            id: "current", channelId: "PBSKQED.us", title: "Secrets of the Dead", listingDescription: "Provider",
            start: fixture.start, end: fixture.end, sourceID: sourceID
        ))
        try context.save()
        let sync = fixture.supplement(url: url, coordinator: LocalStoreWriteCoordinator())
        let now = Date()
        try await sync.sync(container: fixture.container, enabled: true, fence: .live, now: now)
        #expect(try fixture.row().artworkURL != nil)
        // Keep a future row in the snapshot so expiry, not simply an exhausted
        // programme horizon, is what removes the otherwise matching artwork.
        let cached = try #require(EPGEnrichmentCache.read(from: fixture.cacheURL))
        var future = try #require(cached.programmes.first)
        let later = ParsedProgramme(
            channelId: future.channelId, title: future.title, subtitle: future.subtitle, description: future.description, categories: future.categories,
            start: now.addingTimeInterval(3 * 86400), end: now.addingTimeInterval(3 * 86400 + 3600)
        )
        future.artworkURL = "https://example.com/art.jpg"
        try EPGEnrichmentCache(
            url: cached.url, checkedAt: cached.checkedAt, channelIDs: cached.channelIDs,
            programmes: [future, later], lastModified: cached.lastModified, entityTag: cached.entityTag
        ).write(to: fixture.cacheURL)
        failed.withLock { $0 = true }
        try await sync.sync(container: fixture.container, enabled: true, fence: .live, now: now.addingTimeInterval(25 * 3600))
        #expect(try fixture.row().artworkURL != nil)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentSettings.checkedKey) == now.timeIntervalSince1970)
        try await sync.sync(container: fixture.container, enabled: true, fence: .live, now: now.addingTimeInterval(49 * 3600))
        #expect(try fixture.row().artworkURL == nil)
        #expect(try fixture.row().enrichmentBaseline == nil)
        #expect(try fixture.row().listingDescription == "Provider")
    }

    @Test func `removing the verified mapping restores already enriched programmes`() async throws {
        let server = try GuideHTTPServer { _ in .init(body: Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/art.jpg")) }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let context = ModelContext(fixture.container)
        let sourceID = try #require(try context.fetch(FetchDescriptor<EPGSource>()).first).id
        context.insert(EPGListing(
            id: "current", channelId: "PBSKQED.us", title: "Secrets of the Dead", listingDescription: "Provider",
            start: fixture.start, end: fixture.end, sourceID: sourceID
        ))
        try context.save()
        let sync = fixture.supplement(url: url, coordinator: LocalStoreWriteCoordinator())
        try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(try fixture.row().artworkURL != nil)
        context.insert(LiveStream(id: "collision", streamId: 2, name: "Different station", epgChannelId: "PBSKQED.us"))
        try context.save()
        try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(try fixture.row().artworkURL == nil)
        #expect(try fixture.row().enrichmentBaseline == nil)
    }
}

extension EPGEnrichmentSyncTests {
    @Test(arguments: [true, false]) func `hiding a previously enriched channel or category restores provider metadata`(hideChannel: Bool) async throws {
        let server = try GuideHTTPServer { _ in .init(body: Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/art.jpg")) }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let context = ModelContext(fixture.container)
        let sourceID = try #require(try context.fetch(FetchDescriptor<EPGSource>()).first).id
        let stream = try #require(try context.fetch(FetchDescriptor<LiveStream>()).first)
        let category = Category(apiId: "pbs", name: "PBS", parentId: 0, type: .live)
        category.epgEnrichmentEnabled = true
        stream.categoryId = category.id
        context.insert(category)
        context.insert(EPGListing(id: "current", channelId: "PBSKQED.us", title: "Secrets of the Dead", listingDescription: "Provider",
                                  start: fixture.start, end: fixture.end, sourceID: sourceID))
        try context.save()
        let sync = fixture.supplement(url: url, coordinator: LocalStoreWriteCoordinator())
        try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(try fixture.row().artworkURL != nil)
        stream.isHidden = hideChannel
        category.isHidden = !hideChannel
        try context.save()
        let report = try await sync.sync(container: fixture.container, enabled: true, fence: .live)
        #expect(report.verifiedStations == 0)
        #expect(report.changedProgrammes == 1)
        #expect(try fixture.row().artworkURL == nil)
        #expect(try fixture.row().listingDescription == "Provider")
    }

    @Test func `an external 304 updates the check date without replacing the cache`() async throws {
        let requests = Mutex<[String]>([])
        let server = try GuideHTTPServer { raw in
            requests.withLock { $0.append(raw) }
            if raw.lowercased().contains("if-modified-since:") { return .init(status: 304) }
            return .init(headers: ["Last-Modified": Self.modified], body: Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/art.jpg"))
        }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let sync = fixture.supplement(url: url, coordinator: LocalStoreWriteCoordinator())
        let now = Date()
        try await sync.sync(container: fixture.container, enabled: true, fence: .live, now: now)
        let cached = try #require(EPGEnrichmentCache.read(from: fixture.cacheURL))
        let future = ParsedProgramme(
            channelId: "KQED-DT.us_locals1", title: "Later", subtitle: nil, description: "", categories: [],
            start: now.addingTimeInterval(2 * 86400), end: now.addingTimeInterval(2 * 86400 + 3600)
        )
        try EPGEnrichmentCache(
            url: cached.url, checkedAt: cached.checkedAt, channelIDs: cached.channelIDs,
            programmes: cached.programmes + [future], lastModified: cached.lastModified, entityTag: cached.entityTag
        ).write(to: fixture.cacheURL)
        let later = now.addingTimeInterval(25 * 3600)
        let report = try await sync.sync(container: fixture.container, enabled: true, fence: .live, now: later)
        #expect(report.state == .unchanged)
        #expect(report.checkedAt == later)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentSettings.failedKey) == 0)
        let updated = try #require(EPGEnrichmentCache.read(from: fixture.cacheURL))
        #expect(updated.checkedAt == later)
        #expect(updated.programmes.count == cached.programmes.count + 1)
        #expect(requests.withLock { $0.count } == 2)
        #expect(requests.withLock { $0.last?.lowercased().contains("if-modified-since:") } == true)
    }

    @Test func `cancelling a metadata download retries immediately after a provider 304`() async throws {
        let downloads = Mutex(0)
        let server = try GuideHTTPServer { raw in
            if raw.hasPrefix("GET /metadata") {
                let attempt = downloads.withLock { $0 += 1; return $0 }
                return .init(body: Fixture.document(channel: "KQED-DT.us_locals1", artwork: "https://example.com/art.jpg"), delay: attempt == 1 ? 2 : 0)
            }
            if raw.lowercased().contains("if-modified-since:") { return .init(status: 304) }
            return .init(headers: ["Last-Modified": Self.modified], body: Fixture.document(channel: "PBSKQED.us"))
        }
        defer { server.stop() }
        let url = try await server.start()
        let fixture = try Fixture(providerURL: url)
        defer { fixture.cleanup() }
        let manager = fixture.manager(externalURL: url.deletingLastPathComponent().appendingPathComponent("metadata"))
        #expect(await manager.syncAllSources() == .succeeded)
        // A failed/cancelled attempt stored by the old build must not preserve
        // the old one-hour suppression after upgrading either.
        fixture.defaults.set(Date().timeIntervalSince1970, forKey: "lume.epgEnrichment.attempted")
        let task = Task { await manager.syncAllSources(enrichProgrammes: true) }
        defer { task.cancel() }
        for _ in 0 ..< 200 where downloads.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(downloads.withLock { $0 } == 1)
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentSettings.failedKey) == 0)
        #expect(fixture.defaults.double(forKey: EPGEnrichmentSettings.checkedKey) == 0)
        #expect(EPGEnrichmentSettings.isDue(defaults: fixture.defaults))
        #expect(EPGEnrichmentCache.read(from: fixture.cacheURL) == nil)
        #expect(try fixture.row().artworkURL == nil)
        #expect(await manager.syncAllSources(enrichProgrammes: true) == .succeeded)
        #expect(downloads.withLock { $0 } == 2)
        #expect(await manager.enrichmentReport?.state == .downloaded)
        #expect(try fixture.row().artworkURL != nil)
    }
}

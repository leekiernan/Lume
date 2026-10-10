import Foundation
@testable import Lume
import SwiftData
import Synchronization
import Testing

@Suite(.readsGlobalState)
@MainActor
struct EPGConditionalPublicationTests {
    private nonisolated static let modified = "Wed, 07 Oct 2026 12:00:00 GMT"
    private nonisolated static let document = """
    <tv><programme start="20500101120000 +0000" stop="20500101130000 +0000" channel="news"><title>News</title></programme></tv>
    """

    private func store(url: URL) throws -> ModelContainer {
        let schema = Schema([EPGSource.self, EPGListing.self, LiveStream.self, Category.self, Playlist.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        container.mainContext.insert(EPGSource(name: "Guide", url: url.absoluteString))
        container.mainContext.insert(LiveStream(id: "news", streamId: 1, name: "News", epgChannelId: "news"))
        try container.mainContext.save()
        return container
    }

    private func source(in container: ModelContainer) throws -> EPGSource {
        try #require(try ModelContext(container).fetch(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.name == "Guide" })).first)
    }

    @Test func `not modified preserves rows and generation while updating the successful check date`() async throws {
        let requests = Mutex<[String]>([])
        let server = try GuideHTTPServer { raw in
            requests.withLock { $0.append(raw) }
            if raw.lowercased().contains("if-modified-since:") { return .init(status: 304) }
            return .init(headers: ["Last-Modified": Self.modified], body: Self.document)
        }
        defer { server.stop() }
        let container = try await store(url: server.start())
        let shadowed = EPGSource(name: "Secondary", url: "file:///unused.xml")
        shadowed.addedAt = .distantFuture
        container.mainContext.insert(shadowed)
        try container.mainContext.save()
        let manager = EPGSyncManager(modelContainer: container, writeCoordinator: LocalStoreWriteCoordinator())
        #expect(await manager.syncAllSources() == .succeeded)
        let first = try #require(try ModelContext(container).fetch(FetchDescriptor<EPGListing>()).first)
        let identity = first.persistentModelID
        let checked = Date()
        #expect(await manager.syncAllSources() == .succeeded)
        let stored = try source(in: container)
        #expect(stored.committedGeneration == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<EPGSource>()).allSatisfy { $0.committedGeneration == 1 })
        #expect(stored.snapshotProgrammeCount == 1)
        #expect(stored.lastModified == Self.modified)
        #expect(try #require(stored.lastSyncDate) >= checked)
        #expect(try ModelContext(container).fetch(FetchDescriptor<EPGListing>()).first?.persistentModelID == identity)
        #expect(requests.withLock { $0.count } == 2)
    }

    @Test func `missing local rows force an unconditional download despite saved validators`() async throws {
        let requests = Mutex<[String]>([])
        let server = try GuideHTTPServer { raw in
            requests.withLock { $0.append(raw) }
            if raw.lowercased().contains("if-modified-since:") { return .init(status: 304) }
            return .init(headers: ["Last-Modified": Self.modified], body: Self.document)
        }
        defer { server.stop() }
        let container = try await store(url: server.start())
        let manager = EPGSyncManager(modelContainer: container, writeCoordinator: LocalStoreWriteCoordinator())
        #expect(await manager.syncAllSources() == .succeeded)
        let context = ModelContext(container)
        for listing in try context.fetch(FetchDescriptor<EPGListing>()) {
            context.delete(listing)
        }
        try context.save()
        #expect(await manager.syncAllSources() == .succeeded)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<EPGListing>()) == 1)
        #expect(try source(in: container).committedGeneration == 2)
        #expect(requests.withLock { $0.allSatisfy { !$0.lowercased().contains("if-modified-since:") } })
    }

    @Test func `a malformed response cannot overwrite snapshot validators`() async throws {
        let broken = Mutex(false)
        let server = try GuideHTTPServer { _ in
            if broken.withLock({ $0 }) { return .init(headers: ["Last-Modified": "bad-new-date"], body: "<tv><programme") }
            return .init(headers: ["Last-Modified": Self.modified], body: Self.document)
        }
        defer { server.stop() }
        let container = try await store(url: server.start())
        let manager = EPGSyncManager(modelContainer: container, writeCoordinator: LocalStoreWriteCoordinator())
        #expect(await manager.syncAllSources() == .succeeded)
        broken.withLock { $0 = true }
        #expect(await manager.syncAllSources() == .failed)
        let stored = try source(in: container)
        #expect(stored.lastModified == Self.modified)
        #expect(stored.committedGeneration == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<EPGListing>()) == 1)
    }
}

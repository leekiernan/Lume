import Foundation
@testable import Lume
import Testing

extension LumeMetadataDeliveryTests {
    private func statusItem(_ status: String, id: Int = 603) -> String {
        """
        {"tmdb_id":\(id),"status":"\(status)"}
        """
    }

    @Test func `pending foreground detail retains main device fallback`() async throws {
        let id = 987_681
        let (_, source, client, _) = try fixture(body: envelope([statusItem("pending", id: id)]))
        let tmdb = TMDBClient(session: StubURLProtocol.makeSession(), token: "test", language: "en-GB")
        let router = LumeTitleMetadataRouter(tmdb: tmdb, proxy: client)
        StubURLProtocol.register(host: "api.themoviedb.org", path: "/3/movie/\(id)", response: .init(body: #"{"overview":"Main fallback"}"#))
        let value = try #require(try await router.details(id: id, type: .movie, source: source))
        #expect(value.overview == "Main fallback" && value.proxyReceipt == nil)
    }

    @Test func `proxy not found cannot suppress main device fallback`() async throws {
        let id = 987_682
        let (_, source, client, _) = try fixture(body: envelope([statusItem("not_found", id: id)]))
        let router = LumeTitleMetadataRouter(tmdb: TMDBClient(session: StubURLProtocol.makeSession(), token: "test", language: "en-GB"), proxy: client)
        StubURLProtocol.register(host: "api.themoviedb.org", path: "/3/movie/\(id)", response: .init(body: #"{"overview":"Main fallback"}"#))
        let value = try #require(try await router.details(id: id, type: .movie, source: source))
        #expect(value.overview == "Main fallback" && value.proxyReceipt == nil)
    }

    @Test(arguments: ["unavailable", "unsupported_language", "unknown"])
    func `non authoritative statuses retain per title device fallback`(_ status: String) async throws {
        let id = ["unavailable": 987_683, "unsupported_language": 987_684, "unknown": 987_685][status]!
        let (_, source, client, _) = try fixture(body: envelope([statusItem(status, id: id)]))
        StubURLProtocol.register(host: "api.themoviedb.org", path: "/3/movie/\(id)", response: .init(body: #"{"overview":"Device fallback"}"#))
        let router = LumeTitleMetadataRouter(tmdb: TMDBClient(session: StubURLProtocol.makeSession(), token: "test", language: "en-GB"), proxy: client)
        let value = try #require(try await router.details(id: id, type: .movie, source: source))
        #expect(value.overview == "Device fallback" && value.proxyReceipt == nil)
    }

    @Test func `pending cache is short and retains ready siblings and validators`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([item(), statusItem("pending", id: 604)]))
        #expect(try await fetch(client, source, ids: [603, 604]).keys.sorted() == [603])
        StubURLProtocol.register(host: host, pathSuffix: "/metadata", response: .init(body: envelope([item(), item(id: 604)])))
        #expect(try await fetch(client, source, ids: [603, 604], time: now.addingTimeInterval(9)).keys.sorted() == [603])
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
        #expect(try await fetch(client, source, ids: [603, 604], time: now.addingTimeInterval(10)).keys.sorted() == [603, 604])
        #expect(StubURLProtocol.requests(forHost: host).count == 3)
        #expect(StubURLProtocol.requests(forHost: host).last?.value(forHTTPHeaderField: "If-None-Match") == "\"batch-one\"")
    }

    @Test func `pending 304 preserves status and cannot stall later ready delivery`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([statusItem("pending")]))
        #expect(try await fetch(client, source).isEmpty)
        StubURLProtocol.register(host: host, pathSuffix: "/metadata", response: .init(status: 304))
        let repeated = try await client.fetch(source: source, type: .movie, ids: [603], language: "en-GB", now: now.addingTimeInterval(10))
        guard case let .available(details, statuses) = repeated else { Issue.record("Expected retained pending body"); return }
        #expect(details.isEmpty && statuses[603] == .pending)
        StubURLProtocol.register(host: host, pathSuffix: "/metadata", response: .init(body: envelope([item()])))
        #expect(try await fetch(client, source, time: now.addingTimeInterval(20)).count == 1)
        #expect(StubURLProtocol.requests(forHost: host).count == 4)
    }

    @Test(arguments: ["pending", "not_found", "unknown"])
    func `status never certifies an attached payload unless ok`(_ status: String) async throws {
        let entry = item().replacingOccurrences(of: #""tmdb_id":603,"#, with: #""tmdb_id":603,"status":""# + status + #"","#)
        let (_, source, client, _) = try fixture(body: envelope([entry]))
        #expect(try await fetch(client, source).isEmpty)
    }

    @Test func `duplicate statuses and unsolicited IDs cannot defer requested titles`() async throws {
        let (_, source, client, _) = try fixture(body: envelope([item(), statusItem("pending"), statusItem("pending", id: 999)]))
        let result = try await client.fetch(source: source, type: .movie, ids: [603], language: "en-GB", now: now)
        guard case let .available(details, statuses) = result else { Issue.record("Expected batch"); return }
        #expect(details.isEmpty && statuses.isEmpty)
    }

    @Test func `smaller batch splits preserve per item statuses`() async throws {
        let (_, source, client, _) = try fixture(body: envelope([item(), statusItem("pending", id: 604), statusItem("not_found", id: 605)]), limit: 1)
        let result = try await client.fetch(source: source, type: .movie, ids: [603, 604, 605], language: "en-GB", now: now)
        guard case let .available(details, statuses) = result else { Issue.record("Expected split batch"); return }
        #expect(details.keys.sorted() == [603])
        #expect(statuses[604] == .pending && statuses[605] == .notFound)
    }

    @Test func `indexer keeps pending rows unresolved but can apply ready siblings`() async throws {
        let (_, source, client, _) = try fixture(body: envelope([item(), statusItem("pending", id: 604), statusItem("not_found", id: 605)]))
        let container = try FieldFixtures.makeContainer()
        let indexer = ContentIndexer(modelContainer: container, tmdbClient: TMDBClient(token: nil, language: "en-GB"))
        let pending = [603, 604, 605].map { id in
            ContentIndexer.PendingItem(kind: .movie, id: "content-\(id)", title: "Title", year: nil,
                                       existingTMDBId: id, needsEnrichment: true, source: source)
        }
        let values = try await indexer.prefetchMetadata(pending, client: client)
        let ready = try await indexer.resolve(pending[0], prefetched: values[pending[0].id])
        #expect(ready.details?.proxyReceipt?.tmdbID == 603 && !ready.usedNetwork)
        await #expect(throws: LumeMetadataError.pending) { try await indexer.resolve(pending[1], prefetched: values[pending[1].id]) }
        let missing = try await indexer.resolve(pending[2], prefetched: values[pending[2].id])
        #expect(missing.details == nil && !missing.usedNetwork)
    }

    @Test func `stuck background pending falls back after one minute`() async throws {
        let id = 987_686
        let (_, source, client, _) = try fixture(body: envelope([statusItem("pending", id: id)]))
        let container = try FieldFixtures.makeContainer()
        let indexer = ContentIndexer(modelContainer: container, tmdbClient: TMDBClient(session: StubURLProtocol.makeSession(), token: "test", language: "en-GB"))
        let item = ContentIndexer.PendingItem(kind: .movie, id: "content-\(id)", title: "Title", year: nil,
                                              existingTMDBId: id, needsEnrichment: true, source: source)
        let first = try await indexer.prefetchMetadata([item], client: client, now: now)
        await #expect(throws: LumeMetadataError.pending) { try await indexer.resolve(item, prefetched: first[item.id]) }
        let shortly = try await indexer.prefetchMetadata([item], client: client, now: now.addingTimeInterval(59))
        await #expect(throws: LumeMetadataError.pending) { try await indexer.resolve(item, prefetched: shortly[item.id]) }
        let expired = try await indexer.prefetchMetadata([item], client: client, now: now.addingTimeInterval(60))
        #expect(expired.isEmpty)
        StubURLProtocol.register(host: "api.themoviedb.org", path: "/3/movie/\(id)", response: .init(body: #"{"overview":"Main background fallback"}"#))
        let result = try await indexer.resolve(item, prefetched: expired[item.id])
        #expect(result.usedNetwork && result.details?.overview == "Main background fallback")
        #expect(result.details?.proxyReceipt == nil)
    }

    @Test(arguments: ["outage", "ordinary-provider", "malformed", "not-found"])
    func `background proxy misses retain configured device fallback`(_ variant: String) async throws {
        let id = ["outage": 987_687, "ordinary-provider": 987_688, "malformed": 987_689, "not-found": 987_690][variant]!
        let status = variant == "outage" ? 503 : variant == "ordinary-provider" ? 404 : 200
        let body = variant == "not-found" ? envelope([statusItem("not_found", id: id)]) : "invalid"
        let (_, source, client, _) = try fixture(body: body, status: status)
        let indexer = try ContentIndexer(modelContainer: FieldFixtures.makeContainer(),
                                         tmdbClient: TMDBClient(session: StubURLProtocol.makeSession(), token: "test", language: "en-GB"))
        let item = ContentIndexer.PendingItem(kind: .movie, id: "content-\(id)", title: "Title", year: nil,
                                              existingTMDBId: id, needsEnrichment: true, source: source)
        let prefetched = try await indexer.prefetchMetadata([item], client: client)
        #expect(prefetched.isEmpty)
        StubURLProtocol.register(host: "api.themoviedb.org", path: "/3/movie/\(id)", response: .init(body: #"{"overview":"Existing device path"}"#))
        let result = try await indexer.resolve(item, prefetched: prefetched[item.id])
        #expect(result.usedNetwork && result.details?.overview == "Existing device path")
        #expect(result.details?.proxyReceipt == nil)
    }

    @Test func `background pending budget is scoped to the authenticated source`() async throws {
        let (playlist, source, client, _) = try fixture(body: envelope([statusItem("pending")]))
        let indexer = try ContentIndexer(modelContainer: FieldFixtures.makeContainer(), tmdbClient: TMDBClient(token: nil, language: "en-GB"))
        let first = ContentIndexer.PendingItem(kind: .movie, id: "content", title: "Title", year: nil,
                                               existingTMDBId: 603, needsEnrichment: true, source: source)
        #expect(try await !indexer.prefetchMetadata([first], client: client, now: now).isEmpty)
        #expect(try await indexer.prefetchMetadata([first], client: client, now: now.addingTimeInterval(60)).isEmpty)
        playlist.username = "another-account"
        let changed = try #require(LumeProxySource(playlist: playlist))
        let next = ContentIndexer.PendingItem(kind: .movie, id: "content", title: "Title", year: nil,
                                              existingTMDBId: 603, needsEnrichment: true, source: changed)
        let values = try await indexer.prefetchMetadata([next], client: client, now: now.addingTimeInterval(60))
        await #expect(throws: LumeMetadataError.pending) { try await indexer.resolve(next, prefetched: values[next.id]) }
    }
}

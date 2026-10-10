import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LumeMetadataDeliveryTests {
    let now = Date()

    func item(id: Int = 603, type: LumeMetadataKind = .movie, age: TimeInterval = 3600) -> String {
        let date = ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
        let specific = type == .movie ? #""runtime":90,"release_dates":{"results":[]},"belongs_to_collection":null"#
            : #""episode_run_time":[45],"content_ratings":{"results":[]}"#
        return """
        {"tmdb_id":\(id),"lume_meta":{"v":1,"tmdb":"\(date)","artwork":"\(date)"},"tmdb":{
          "id":\(id),"poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg","tagline":null,
          "overview":"Synopsis","vote_average":8.7,"genres":[{"name":"Drama"}],
          "credits":{"cast":[{"id":7,"name":"Actor","order":0,"profile_path":"/actor.jpg"}]},
          "similar":{"results":[{"id":8}]},"videos":{"results":[]},
          "images":{"logos":[{"file_path":"/english.png","iso_639_1":"en"},{"file_path":"/german.png","iso_639_1":"de"}]},
          "external_ids":{"imdb_id":"tt0133093"},\(specific)}}
        """
    }

    func envelope(_ items: [String], type: LumeMetadataKind = .movie, language: String = "en-GB", version: Int = 1) -> String {
        """
        {"v":\(version),"type":"\(type.rawValue)","language":"\(language)","items":[\(items.joined(separator: ","))]}
        """
    }

    func fixture(body: String, status: Int = 200, limit: Int = 50, languages: [String] = ["en-GB"]) throws
        -> (Playlist, LumeProxySource, LumeMetadataClient, String)
    {
        let host = UUID().uuidString.lowercased() + ".example.com"
        let playlist = Playlist(name: "Proxy", serverURL: "https://\(host)/panel?token=a%26b", username: "test&user", password: "test?pass")
        let source = try #require(LumeProxySource(playlist: playlist))
        let languageJSON = try #require(String(data: JSONEncoder().encode(languages), encoding: .utf8))
        StubURLProtocol.register(host: host, pathSuffix: "/capabilities", response: .init(body: """
        {"v":1,"metadata":{"v":1,"max_batch_size":\(limit),"languages":\(languageJSON)}}
        """))
        StubURLProtocol.register(host: host, pathSuffix: "/metadata", response: .init(status: status, body: body, headers: ["ETag": "\"batch-one\""]))
        let session = StubURLProtocol.makeSession()
        return (playlist, source, LumeMetadataClient(session: session, capabilities: LumeProxyCapabilityStore(session: session)), host)
    }

    func fetch(_ client: LumeMetadataClient, _ source: LumeProxySource, ids: [Int] = [603], language: String = "en-GB", time: Date? = nil) async throws
        -> [Int: TMDBTitleDetails]
    {
        let result = try await client.fetch(source: source, type: .movie, ids: ids, language: language, now: time ?? now)
        guard case let .available(items, _) = result else {
            Issue.record("Expected a valid batch")
            return [:]
        }
        return items
    }

    @Test func `complete proxy details work without a device token and retain source age`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([item()]))
        let router = LumeTitleMetadataRouter(tmdb: TMDBClient(token: nil, language: "en-GB"), proxy: client)
        let details = try #require(try await router.details(id: 603, type: .movie, source: source))
        #expect(details.posterPath == "/poster.jpg")
        #expect(details.logoPath == "/english.png")
        #expect(details.cast.first?.tmdbPersonId == 7)
        #expect(details.imdbId == "tt0133093")
        #expect(details.runtimeMinutes == 90 && details.genreNames == ["Drama"])
        #expect(details.proxyReceipt?.sourceIdentity == source.identity)
        #expect(abs((details.proxyReceipt?.tmdbAt.timeIntervalSince(now) ?? 0) + 3600) < 1)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test func `batch IDs are deduplicated sorted and account query is preserved`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([item(), item(id: 7)]))
        _ = try await fetch(client, source, ids: [603, 7, 603, -1])
        let request = try #require(StubURLProtocol.requests(forHost: host).last)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/panel/lume/v1/metadata")
        #expect(components.queryItems?.contains(URLQueryItem(name: "ids", value: "7,603")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "username", value: "test&user")) == true)
        #expect(components.queryItems?.contains(URLQueryItem(name: "token", value: "a&b")) == true)
    }

    @Test func `smaller advertised batches are respected`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([item()]), limit: 2)
        _ = try await fetch(client, source, ids: [1, 2, 3, 4, 603])
        let requests = StubURLProtocol.requests(forHost: host).filter { $0.url?.path.hasSuffix("metadata") == true }
        #expect(requests.count == 3)
        for request in requests {
            let values = try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
            #expect((values?.first { $0.name == "ids" }?.value?.split(separator: ",").count ?? 99) <= 2)
        }
    }

    @Test(arguments: ["missing-group", "empty-detail", "wrong-id", "old", "future", "unknown-stamp", "duplicate"])
    func `incomplete ambiguous or stale titles cannot certify completion`(_ variant: String) async throws {
        var entry = item()
        switch variant {
        case "missing-group": entry = entry.replacingOccurrences(of: #""similar":{"results":[{"id":8}]},"#, with: "")
        case "empty-detail": entry = #"{"tmdb_id":603,"lume_meta":{"v":1},"tmdb":{"id":603}}"#
        case "wrong-id": entry = entry.replacingOccurrences(of: #""id":603"#, with: #""id":604"#)
        case "old": entry = item(age: 15 * 24 * 3600)
        case "future": entry = item(age: -3600)
        case "unknown-stamp": entry = entry.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)
        default: break
        }
        let (_, source, client, _) = try fixture(body: envelope(variant == "duplicate" ? [entry, entry] : [entry]))
        #expect(try await fetch(client, source).isEmpty)
    }

    @Test func `malformed item does not discard other valid items`() async throws {
        let (_, source, client, _) = try fixture(body: envelope(["null", #"{"tmdb_id":"bad"}"#, item()]))
        #expect(try await fetch(client, source).keys.sorted() == [603])
    }

    @Test func `malformed conflicting duplicate still rejects that identity`() async throws {
        let (_, source, client, _) = try fixture(body: envelope([item(), #"{"tmdb_id":603,"tmdb":{"id":604}}"#]))
        #expect(try await fetch(client, source).isEmpty)
    }

    @Test func `retained bytes cannot renew metadata after its source freshness expires`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([item()]))
        #expect(try await fetch(client, source).count == 1)
        StubURLProtocol.register(host: host, pathSuffix: "/metadata", response: .init(status: 304))
        #expect(try await fetch(client, source, time: now.addingTimeInterval(15 * 24 * 3600)).isEmpty)
    }

    @Test(arguments: ["version", "kind", "language", "html"])
    func `invalid envelopes are unavailable not empty successful batches`(_ variant: String) async throws {
        let body: String = switch variant {
        case "version": envelope([item()], version: 2)
        case "kind": envelope([item()], type: .series)
        case "language": envelope([item()], language: "de-DE")
        default: "<html>error</html>"
        }
        let (_, source, client, _) = try fixture(body: body)
        guard case .unavailable = try await client.fetch(source: source, type: .movie, ids: [603], language: "en-GB", now: now) else {
            Issue.record("Wrong envelope must not establish completion")
            return
        }
    }

    @Test func `unsupported language falls back without a metadata request`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([item()]))
        let router = LumeTitleMetadataRouter(tmdb: TMDBClient(token: nil, language: "de-DE"), proxy: client)
        #expect(try await router.details(id: 603, type: .movie, source: source) == nil)
        #expect(StubURLProtocol.requests(forHost: host).count == 1)
    }

    @Test func `configured additional language uses the same localized logo normalization`() async throws {
        let (_, source, client, _) = try fixture(body: envelope([item()], language: "de-DE"), languages: ["de-DE"])
        #expect(try await fetch(client, source, language: "de-DE")[603]?.logoPath == "/german.png")
    }

    @Test func `series use TV runtime and complete content rating group`() async throws {
        let (_, source, client, _) = try fixture(body: envelope([item(type: .series)], type: .series))
        guard case let .available(items, _) = try await client.fetch(source: source, type: .series, ids: [603], language: "en-GB", now: now) else {
            Issue.record("Expected series batch")
            return
        }
        #expect(items[603]?.runtimeMinutes == 45)
        #expect(items[603]?.collectionId == nil)
    }

    @Test func `missing item falls back to direct TMDB only when configured`() async throws {
        let (_, source, client, _) = try fixture(body: envelope([]))
        StubURLProtocol.register(host: "api.themoviedb.org", path: "/3/movie/987670", response: .init(body: #"{"overview":"Device fallback"}"#))
        let router = LumeTitleMetadataRouter(tmdb: TMDBClient(session: StubURLProtocol.makeSession(), token: "test", language: "en-GB"), proxy: client)
        let details = try #require(try await router.details(id: 987_670, type: .movie, source: source))
        #expect(details.overview == "Device fallback")
        #expect(details.proxyReceipt == nil)
    }

    @Test func `a 304 reuses actual bytes without making old metadata younger`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([item()]))
        let first = try await fetch(client, source)[603]?.proxyReceipt
        StubURLProtocol.register(host: host, pathSuffix: "/metadata", response: .init(status: 304))
        let second = try await fetch(client, source, time: now.addingTimeInterval(301))[603]?.proxyReceipt
        #expect(first == second)
        #expect(StubURLProtocol.requests(forHost: host).last?.value(forHTTPHeaderField: "If-None-Match") == "\"batch-one\"")
    }

    @Test func `a 304 with no retained payload retries once and cannot grant proof`() async throws {
        let (_, source, client, host) = try fixture(body: "", status: 304)
        guard case .unavailable = try await client.fetch(source: source, type: .movie, ids: [603], language: "en-GB", now: now) else {
            Issue.record("No bytes means no metadata")
            return
        }
        #expect(StubURLProtocol.requests(forHost: host).count == 3)
    }

    @Test(arguments: [404, 503])
    func `endpoint failures are cooled down across different batches`(_ status: Int) async throws {
        let (_, source, client, host) = try fixture(body: "", status: status)
        _ = try await client.fetch(source: source, type: .movie, ids: [603], language: "en-GB", now: now)
        _ = try await client.fetch(source: source, type: .movie, ids: [604], language: "en-GB", now: now.addingTimeInterval(59))
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
        if status == 503 {
            _ = try await client.fetch(source: source, type: .movie, ids: [604], language: "en-GB", now: now.addingTimeInterval(60))
            #expect(StubURLProtocol.requests(forHost: host).count == 3)
        }
    }

    @Test func `cancelled reader cannot receive completion`() async throws {
        let (_, source, client, _) = try fixture(body: envelope([item()]))
        let task = Task {
            try Task.checkCancellation()
            return try await client.fetch(source: source, type: .movie, ids: [603], language: "en-GB", now: now)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func `same authenticated batch is coalesced for concurrent readers`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([item()]))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    _ = try await client.fetch(source: source, type: .movie, ids: [603], language: "en-GB")
                }
            }
            try await group.waitForAll()
        }
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test func `account edit cannot reuse another accounts cached batch`() async throws {
        let (playlist, source, client, host) = try fixture(body: envelope([item()]))
        _ = try await fetch(client, source)
        playlist.username = "other-account"
        let changed = try #require(LumeProxySource(playlist: playlist))
        let details = try await fetch(client, changed)[603]
        #expect(details?.proxyReceipt?.sourceIdentity == changed.identity)
        #expect(details?.proxyReceipt?.sourceIdentity != source.identity)
        #expect(StubURLProtocol.requests(forHost: host).count == 4)
    }

    @Test func `indexer prefetch groups titles and works without a device key`() async throws {
        let (_, source, client, host) = try fixture(body: envelope([item(), item(id: 604)]))
        let container = try FieldFixtures.makeContainer()
        let indexer = ContentIndexer(modelContainer: container, tmdbClient: TMDBClient(token: nil, language: "en-GB"))
        let pending = [603, 604].map { id in
            ContentIndexer.PendingItem(kind: .movie, id: "content-\(id)", title: "Title", year: nil,
                                       existingTMDBId: id, needsEnrichment: true, source: source)
        }
        let values = try await indexer.prefetchMetadata(pending, client: client)
        #expect(values.count == 2)
        let result = try await indexer.resolve(pending[0], prefetched: values[pending[0].id])
        #expect(result.details?.proxyReceipt?.tmdbID == 603)
        #expect(!result.usedNetwork)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test func `whole batch outage preserves paced device indexing and cools down proxy requests`() async throws {
        let (_, source, client, host) = try fixture(body: "", status: 503)
        let container = try FieldFixtures.makeContainer()
        let indexer = ContentIndexer(modelContainer: container, tmdbClient: TMDBClient(token: "test", language: "en-GB"))
        let pending = (1 ... 50).map { id in
            ContentIndexer.PendingItem(kind: .movie, id: "content-\(id)", title: "Title", year: nil,
                                       existingTMDBId: id, needsEnrichment: true, source: source)
        }
        #expect(try await indexer.prefetchMetadata(pending, client: client).isEmpty)
        #expect(try await indexer.prefetchMetadata(pending, client: client).isEmpty)
        #expect(StubURLProtocol.requests(forHost: host).count == 2)
    }

    @Test func `indexer rechecks account and TMDB identity before writing`() async throws {
        let (playlist, source, _, _) = try fixture(body: envelope([item()]))
        let container = try FieldFixtures.makeContainer()
        let context = container.mainContext
        context.insert(playlist)
        let movie = Movie(id: "\(playlist.id.uuidString)-movie-1", streamId: 1, name: "Movie")
        movie.tmdbId = 603
        context.insert(movie)
        let indexer = ContentIndexer(modelContainer: container)
        let item = ContentIndexer.PendingItem(kind: .movie, id: movie.id, title: "Movie", year: nil,
                                              existingTMDBId: 603, needsEnrichment: true, source: source)
        let result = ContentIndexer.IndexResult(item: item, resolvedTMDBId: 603, details: nil, usedNetwork: false)
        #expect(await indexer.canApply(result, to: movie, in: context))
        playlist.password = "edited"
        #expect(await !(indexer.canApply(result, to: movie, in: context)))
        playlist.password = "test?pass"
        movie.tmdbId = 604
        #expect(await !(indexer.canApply(result, to: movie, in: context)))
        movie.tmdbId = nil
        #expect(await !(indexer.canApply(result, to: movie, in: context)))
    }

    @Test func `indexer can resolve a missing ID but cannot overwrite a concurrent resolution`() async throws {
        let container = try FieldFixtures.makeContainer()
        let context = container.mainContext
        let movie = Movie(id: "unresolved-movie", streamId: 1, name: "Movie")
        context.insert(movie)
        let indexer = ContentIndexer(modelContainer: container)
        let item = ContentIndexer.PendingItem(kind: .movie, id: movie.id, title: movie.name, year: nil,
                                              existingTMDBId: nil, needsEnrichment: true, source: nil)
        let result = ContentIndexer.IndexResult(item: item, resolvedTMDBId: 603, details: nil, usedNetwork: true)
        #expect(await indexer.canApply(result, to: movie, in: context))
        movie.tmdbId = 604
        #expect(await !(indexer.canApply(result, to: movie, in: context)))
    }
}

import Foundation
@testable import Lume
import SwiftData
import Testing

@Suite(.readsGlobalState)
struct XtreamConditionalFetchTests {
    private struct World {
        let container: ModelContainer
        let playlist: Playlist
        let manager: ContentSyncManager
        let host: String
        let endpoint: XtreamDigestStore.Endpoint

        var action: String {
            switch endpoint {
            case .movies: "get_vod_streams"
            case .series: "get_series"
            case .live: "get_live_streams"
            }
        }

        func serve(_ names: [String], etag: String? = nil, status: Int = 200) {
            let idKey = endpoint == .series ? "series_id" : "stream_id"
            let rows = names.enumerated().map { "{\"\(idKey)\":\($0.offset + 1),\"name\":\"\($0.element)\"}" }
            StubURLProtocol.register(host: host, query: ("action", action), response: .init(
                status: status, body: status == 304 ? "not JSON" : "[" + rows.joined(separator: ",") + "]",
                headers: etag.map { ["ETag": $0] } ?? [:]
            ))
        }

        func sync(reuse: Bool = true) async throws {
            switch endpoint {
            case .movies: try await manager.syncMovies(for: playlist, playlistId: playlist.id, reuseUnchanged: reuse)
            case .series: try await manager.syncSeries(for: playlist, playlistId: playlist.id, reuseUnchanged: reuse)
            case .live: try await manager.syncLiveStreams(for: playlist, playlistId: playlist.id, reuseUnchanged: reuse)
            }
        }

        func names() throws -> [String] {
            let context = ModelContext(container)
            switch endpoint {
            case .movies: return try context.fetch(FetchDescriptor<Movie>()).map(\.name).sorted()
            case .series: return try context.fetch(FetchDescriptor<Series>()).map(\.name).sorted()
            case .live: return try context.fetch(FetchDescriptor<LiveStream>()).map(\.name).sorted()
            }
        }

        func editFirst(delete: Bool = false) throws {
            let context = ModelContext(container)
            switch endpoint {
            case .movies:
                let row = try #require(try context.fetch(FetchDescriptor<Movie>()).first)
                if delete { context.delete(row) } else { row.name = "Edited" }
            case .series:
                let row = try #require(try context.fetch(FetchDescriptor<Series>()).first)
                if delete { context.delete(row) } else { row.name = "Edited" }
            case .live:
                let row = try #require(try context.fetch(FetchDescriptor<LiveStream>()).first)
                if delete { context.delete(row) } else { row.name = "Edited" }
            }
            try context.save()
        }

        var lastRequest: URLRequest? {
            StubURLProtocol.requests(forHost: host).last
        }

        var entry: XtreamDigestStore.Entry? {
            XtreamDigestStore.entry(playlistId: playlist.id, endpoint: endpoint)
        }

        func cleanUp() {
            XtreamDigestStore.removeAll(playlistId: playlist.id)
            SweepSkipDefaults.removeAll(playlistId: playlist.id)
        }
    }

    private func makeWorld(_ endpoint: XtreamDigestStore.Endpoint = .movies) throws -> World {
        let container = try makeTestContainer()
        let host = "xtream-conditional-\(UUID().uuidString.lowercased()).test"
        let playlist = Playlist(name: "Conditional", serverURL: "http://\(host)", username: "u", password: "p")
        let context = ModelContext(container)
        context.insert(playlist)
        try context.save()
        return World(container: container, playlist: playlist,
                     manager: ContentSyncManager(modelContainer: container, xtreamClient: XtreamClient(urlSession: StubURLProtocol.makeSession())),
                     host: host, endpoint: endpoint)
    }

    @Test(arguments: XtreamDigestStore.Endpoint.allCases)
    func `a 304 skips decode import and prune for all bulk endpoints`(endpoint: XtreamDigestStore.Endpoint) async throws {
        let world = try makeWorld(endpoint)
        defer { world.cleanUp() }
        world.serve(["Alpha", "Bravo"], etag: #"W/"v1""#)
        try await world.sync()
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(world.entry?.validator?.etag == #"W/"v1""#)
        try world.editFirst()
        world.serve([], status: 304)
        try await world.sync()

        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == #"W/"v1""#)
        #expect(try world.names().contains("Edited"))
        #expect(try world.names().count == 2)
        #expect(world.entry?.validator?.etag == #"W/"v1""#)
    }

    @Test(arguments: XtreamDigestStore.Endpoint.allCases)
    func `full sync and missing rows bypass conditional requests`(endpoint: XtreamDigestStore.Endpoint) async throws {
        let world = try makeWorld(endpoint)
        defer { world.cleanUp() }
        world.serve(["Alpha", "Bravo"], etag: #""v1""#)
        try await world.sync()
        try world.editFirst()
        try await world.sync(reuse: false)
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(try world.names() == ["Alpha", "Bravo"])
        try world.editFirst(delete: true)
        try await world.sync()
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(try world.names() == ["Alpha", "Bravo"])
    }

    @Test(arguments: ["server", "username", "password"])
    func `validators are scoped to the endpoint account and provider query`(change: String) async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve(["Alpha"], etag: #""v1""#)
        try await world.sync()
        switch change {
        case "server": world.playlist.serverURL += "/other?lineup=2"
        case "username": world.playlist.username = "other-user"
        default: world.playlist.password = "other-password"
        }
        try await world.sync()
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(world.entry?.validator?.requestIdentity.count == 64)
    }

    @Test func `a changed 200 imports and commits its replacement validator`() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve(["Alpha"], etag: #""v1""#)
        try await world.sync()
        world.serve(["Bravo", "Charlie"], etag: #""v2""#)
        try await world.sync()
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == #""v1""#)
        #expect(try world.names() == ["Bravo", "Charlie"])
        #expect(world.entry?.validator?.etag == #""v2""# && world.entry?.rowCount == 2)
    }

    @Test func `matching bytes can acquire or rotate a validator without importing`() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve(["Alpha"])
        try await world.sync()
        try world.editFirst()
        world.serve(["Alpha"], etag: #""v1""#)
        try await world.sync()
        world.serve(["Alpha"], etag: #""v2""#)
        try await world.sync()
        #expect(try world.names() == ["Edited"])
        #expect(world.entry?.validator?.etag == #""v2""#)
        world.serve([], status: 304)
        try await world.sync()
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == #""v2""#)
    }

    @Test func `panels without ETags retain digest skipping and retire an old validator`() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve(["Alpha"], etag: #""v1""#)
        try await world.sync()
        try world.editFirst()
        world.serve(["Alpha"])
        try await world.sync()
        #expect(world.entry?.validator == nil)
        try await world.sync()
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(try world.names() == ["Edited"])
    }

    @Test(arguments: [0, 1])
    func `empty or held back imports never certify an ETag`(count: Int) async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve((1 ... 30).map { "Movie\($0)" }, etag: #""v1""#)
        try await world.sync()
        world.serve(Array(repeating: "Partial", count: count), etag: #""partial""#)
        try await world.sync()
        #expect(world.entry == nil)
        #expect(try world.names().count == 30)
        try await world.sync()
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func `legacy digest entries acquire ETags only after a matching response`() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve(["Alpha"], etag: #""v1""#)
        try await world.sync()
        let original = try #require(world.entry)
        UserDefaults.standard.set("\(original.rowCount):\(original.digest)", forKey: XtreamDigestStore.key(playlistId: world.playlist.id, endpoint: .movies))
        try world.editFirst()
        try await world.sync()
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(try world.names() == ["Edited"])
        #expect(world.entry?.validator?.etag == #""v1""#)
    }

    @Test func `unsolicited 304 retries unconditionally and never certifies missing data`() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve([], etag: #""v1""#, status: 304)
        await #expect(throws: XtreamError.self) { try await world.sync() }
        #expect(StubURLProtocol.requests(forHost: world.host).count == 2)
        #expect(world.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(world.entry == nil)
        #expect(try world.names().isEmpty)
    }

    @Test func `an incomplete sweep cannot certify an ETag`() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve(["Alpha"], etag: #""v1""#)
        try await world.sync()
        let validator = try #require(world.entry?.validator)
        XtreamDigestStore.removeAll(playlistId: world.playlist.id)
        await world.manager.recordXtreamDigest("new", .movies, playlistId: world.playlist.id,
                                               fetchedCount: 2, expectedRowCount: 2, validator: validator)
        #expect(world.entry == nil)
    }

    @Test func `a decoding failure never commits the downloaded validator`() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve(["Alpha"], etag: #""v1""#)
        try await world.sync()
        let committed = world.entry
        StubURLProtocol.register(host: world.host, query: ("action", world.action),
                                 response: .init(body: "invalid JSON", headers: ["ETag": #""broken""#]))
        await #expect(throws: XtreamError.self) { try await world.sync() }
        #expect(world.entry == committed)
        #expect(try world.names() == ["Alpha"])
    }

    @Test func `losing rows during an unchanged request triggers an unconditional recovery`() async throws {
        let world = try makeWorld()
        defer { world.cleanUp() }
        world.serve(["Alpha"], etag: #""v1""#)
        try await world.sync()
        var recoveryRequests = 0
        let result: XtreamFetch<[Int]> = try await world.manager.beginXtreamPhase(
            .movies, playlistId: world.playlist.id, reuseUnchanged: true, progress: nil,
            fetch: { known in
                if let known {
                    let context = ModelContext(world.container)
                    for row in try context.fetch(FetchDescriptor<Movie>()) {
                        context.delete(row)
                    }
                    try context.save()
                    return .unchanged(validator: known.validator)
                }
                recoveryRequests += 1
                return .fetched([1], digest: "recovered")
            }
        )
        guard case let .fetched(rows, _, _) = result else {
            Issue.record("A damaged catalogue must be re-downloaded")
            return
        }
        #expect(rows == [1] && recoveryRequests == 1)
        #expect(world.entry == nil) // Only the subsequent successful import can certify it.
    }

    @Test func `bulk series refresh preserves parent detail metadata`() async throws {
        let world = try makeWorld(.series)
        defer { world.cleanUp() }
        world.serve(["Alpha"], etag: #""v1""#)
        try await world.sync()
        let context = ModelContext(world.container)
        let series = try #require(try context.fetch(FetchDescriptor<Series>()).first)
        let info = try JSONDecoder().decode(XtreamSeriesInfo.self, from: Data(#"{"plot":"Detail plot","cover":"detail.jpg","cast":"Actor","tmdb":"123"}"#.utf8))
        series.applyFetchedEpisodes(FetchedEpisodes(episodes: [], seriesInfo: info), into: context)
        world.serve(["Renamed"], etag: #""v2""#)
        try await world.sync()
        let check = try #require(try ModelContext(world.container).fetch(FetchDescriptor<Series>()).first)
        #expect(check.name == "Renamed" && check.plot == "Detail plot" && check.cover == "detail.jpg")
        #expect(check.cast == "Actor" && check.tmdbId == 123)
    }
}

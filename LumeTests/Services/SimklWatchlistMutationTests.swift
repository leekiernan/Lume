import Foundation
@testable import Lume
import Testing

private final nonisolated class SimklWatchlistWriteStub: URLProtocol {
    enum Mode { case present, absent, anime, notFound, unavailable }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var mode = Mode.present
    private nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset(_ mode: Mode = .present) {
        lock.withLock { Self.mode = mode; requests = [] }
    }

    static var recorded: [URLRequest] {
        lock.withLock { requests }
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var recorded = request
        recorded.httpBody = request.bodyData
        let mode = Self.lock.withLock { Self.requests.append(recorded); return Self.mode }
        let path = request.url!.path
        let body: String
        if path == "/sync/add-to-list" {
            let payload = (try? JSONSerialization.jsonObject(with: recorded.httpBody ?? Data())) as? [String: Any]
            let key = payload?["movies"] == nil ? "shows" : "movies"
            let item = (payload?[key] as? [[String: Any]])?.first
            let status = item?["to"] as? String ?? ""
            body = mode == .notFound ? #"{"added":{"movies":[],"shows":[]},"not_found":{"movies":[{}]}}"#
                : "{\"added\":{\"\(key)\":[{\"to\":\"\(status)\"}]}}"
        } else if path.contains("/movies/") && mode == .present {
            body = #"{"movies":[{"movie":{"ids":{"tmdb":42}}}]}"#
        } else if path.contains("/anime/") && mode == .anime {
            body = #"{"anime":[{"anime_type":"tv","show":{"ids":{"tmdb":42}}}]}"#
        } else { body = "{}" }
        let status = mode == .unavailable ? 503 : (request.httpMethod == "POST" ? 201 : 200)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct SimklWatchlistMutationTests {
    private func client() -> SimklClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SimklWatchlistWriteStub.self]
        return SimklClient(session: URLSession(configuration: config), clientID: "test")
    }

    @Test(arguments: [true, false])
    func `movie writes list status without history or progress fields`(watchlisted: Bool) async throws {
        SimklWatchlistWriteStub.reset()
        #expect(try await client().setWatchlist(.movie(tmdbID: 42), watchlisted: watchlisted, accessToken: "token"))
        let request = try #require(SimklWatchlistWriteStub.recorded.last)
        #expect(request.url?.path == "/sync/add-to-list")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let data = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let movies = try #require(payload["movies"] as? [[String: Any]])
        #expect(Set(payload.keys) == ["movies"])
        #expect(Set(movies[0].keys) == ["ids", "to"])
        #expect(movies[0]["to"] as? String == (watchlisted ? "plantowatch" : "dropped"))
        #expect((movies[0]["ids"] as? [String: Int])?["tmdb"] == 42)
        #expect(!SimklWatchlistWriteStub.recorded.contains { $0.url?.path.contains("history") == true })
        if !watchlisted {
            #expect(SimklWatchlistWriteStub.recorded.first?.url?.path == "/sync/activities")
        }
    }

    @Test func `removal does not move a title outside plan to watch`() async throws {
        SimklWatchlistWriteStub.reset(.absent)
        #expect(try await client().setWatchlist(.movie(tmdbID: 42), watchlisted: false, accessToken: "token"))
        #expect(SimklWatchlistWriteStub.recorded.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func `anime show removal writes dropped under shows`() async throws {
        SimklWatchlistWriteStub.reset(.anime)
        #expect(try await client().setWatchlist(.show(tmdbID: 42), watchlisted: false, accessToken: "token"))
        let data = try #require(SimklWatchlistWriteStub.recorded.last?.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((payload["shows"] as? [[String: Any]])?.first?["to"] as? String == "dropped")
        #expect(payload["movies"] == nil)
    }

    @Test func `unmatched successful HTTP response still fails delivery`() async {
        SimklWatchlistWriteStub.reset(.notFound)
        await #expect(throws: SimklError.itemNotFound) {
            _ = try await client().setWatchlist(.movie(tmdbID: 42), watchlisted: true, accessToken: "token")
        }
    }

    @Test func `failed membership read keeps removal retryable`() async {
        SimklWatchlistWriteStub.reset(.unavailable)
        await #expect(throws: SimklError.server(503)) {
            _ = try await client().setWatchlist(.movie(tmdbID: 42), watchlisted: false, accessToken: "token")
        }
        #expect(SimklWatchlistWriteStub.recorded.count == 1)
    }

    @Test func `episode is not a watchlist target`() async throws {
        SimklWatchlistWriteStub.reset()
        #expect(try await !client().setWatchlist(.episode(showTMDBID: 42, season: 1, episode: 1), watchlisted: true, accessToken: "token"))
        #expect(SimklWatchlistWriteStub.recorded.isEmpty)
    }
}

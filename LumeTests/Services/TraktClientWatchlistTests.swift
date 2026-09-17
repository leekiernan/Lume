import Foundation
@testable import Lume
import Testing

private final nonisolated class TraktWatchlistStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        lock.withLock { requests = [] }
    }

    static func recordedRequests() -> [URLRequest] {
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
        Self.lock.withLock { Self.requests.append(request) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct TraktClientWatchlistTests {
    private func makeClient() -> TraktClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TraktWatchlistStubProtocol.self]
        return TraktClient(
            session: URLSession(configuration: config),
            clientID: "test-client-id",
            clientSecret: "test-client-secret"
        )
    }

    @Test func `adding a movie posts its TMDB id to the watchlist`() async throws {
        TraktWatchlistStubProtocol.reset()

        try await makeClient().addToWatchlist(.movie(tmdbID: 42), accessToken: "token")

        let request = try #require(TraktWatchlistStubProtocol.recordedRequests().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/sync/watchlist")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let json = try requestJSON(request)
        let movies = try #require(json["movies"] as? [[String: Any]])
        let ids = try #require(movies.first?["ids"] as? [String: Any])
        #expect(ids["tmdb"] as? Int == 42)
        #expect(json["shows"] == nil)
    }

    @Test func `removing a series posts a whole show without episode selection`() async throws {
        TraktWatchlistStubProtocol.reset()

        try await makeClient().removeFromWatchlist(.show(tmdbID: 84), accessToken: "token")

        let request = try #require(TraktWatchlistStubProtocol.recordedRequests().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/sync/watchlist/remove")
        let json = try requestJSON(request)
        let shows = try #require(json["shows"] as? [[String: Any]])
        let show = try #require(shows.first)
        let ids = try #require(show["ids"] as? [String: Any])
        #expect(ids["tmdb"] as? Int == 84)
        #expect(show["seasons"] == nil)
        #expect(json["movies"] == nil)
    }

    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

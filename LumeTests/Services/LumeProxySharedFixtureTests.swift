import Foundation
@testable import Lume
import Testing

/// Copied from proxy commit 01234ea. These are the server's actual serialized
/// movie/series responses, not an app-side approximation of its contract.
@MainActor
struct LumeProxySharedFixtureTests {
    private final class ResourceAnchor {}

    private func fixture(_ kind: String) throws -> String {
        let name = "lume-metadata-batch-\(kind)"
        let bundle = Bundle(for: ResourceAnchor.self)
        let sourceURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProxyMetadata/\(name).json")
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ProxyMetadata")
            ?? bundle.url(forResource: name, withExtension: "json") ?? sourceURL
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test(arguments: ["movie", "series"])
    func `server fixtures decode and normalize through production batch delivery`(_ rawKind: String) async throws {
        let body = try fixture(rawKind)
        let kind = try #require(LumeMetadataKind(rawValue: rawKind))
        let ids = kind == .movie ? [603, 372_058, 999_999_999, 999_999_998] : [1429, 999_999_999, 999_999_998]
        let host = UUID().uuidString.lowercased() + ".example.com"
        let source = try #require(LumeProxySource(playlist: Playlist(name: "Proxy", serverURL: "https://\(host)", username: "test", password: "test")))
        StubURLProtocol.register(host: host, pathSuffix: "/capabilities", response: .init(body: #"{"v":1,"metadata":{"v":1,"max_batch_size":50,"languages":["en-GB"],"groups":["tmdb","artwork"]}}"#))
        StubURLProtocol.register(host: host, pathSuffix: "/metadata", response: .init(body: body))
        let session = StubURLProtocol.makeSession()
        let client = LumeMetadataClient(session: session, capabilities: LumeProxyCapabilityStore(session: session))
        // Fixed source clock: checked-in fixtures must not expire over time.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z"))
        let result = try await client.fetch(source: source, type: kind, ids: ids, language: "en-GB", now: now)
        guard case let .available(details, statuses) = result else { Issue.record("Server fixture rejected"); return }
        #expect(details.keys.sorted() == ids.filter { $0 < 999_999_998 }.sorted())
        #expect(statuses[999_999_999] == .notFound && statuses[999_999_998] == .pending)
        for id in ids where id < 999_999_998 {
            let value = try #require(details[id])
            #expect(value.overview?.isEmpty == false && !value.cast.isEmpty)
            #expect(value.posterPath != nil && !value.genreNames.isEmpty)
            #expect(value.proxyReceipt?.matches(source: source, tmdbID: id, language: "en-GB") == true)
            #expect(value.proxyReceipt?.tmdbAt == ISO8601DateFormatter().date(from: "2026-10-10T03:00:00Z"))
        }
    }

    @Test(arguments: ["movie", "series"])
    func `router delivers shared fixtures without calling configured device TMDB`(_ rawKind: String) async throws {
        // Keep the real payload unchanged, but rebase its stamps because the
        // router uses the wall clock. The raw-byte test above keeps a fixed clock.
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let body = try fixture(rawKind).replacingOccurrences(of: "2026-10-10T03:00:00Z", with: stamp)
        let kind = try #require(LumeMetadataKind(rawValue: rawKind))
        let ids = kind == .movie ? [603, 372_058] : [1429]
        let host = UUID().uuidString.lowercased() + ".example.com"
        let source = try #require(LumeProxySource(playlist: Playlist(name: "Proxy", serverURL: "https://\(host)", username: "test", password: "test")))
        StubURLProtocol.register(host: host, pathSuffix: "/capabilities", response: .init(body: #"{"v":1,"metadata":{"v":1,"max_batch_size":50,"languages":["en-GB"],"groups":["tmdb","artwork"]}}"#))
        StubURLProtocol.register(host: host, pathSuffix: "/metadata", response: .init(body: body))
        let proxySession = StubURLProtocol.makeSession()
        defer { proxySession.invalidateAndCancel() }
        let proxy = LumeMetadataClient(session: proxySession, capabilities: LumeProxyCapabilityStore(session: proxySession))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedDeviceTMDBProtocol.self]
        let deviceSession = URLSession(configuration: configuration)
        defer { deviceSession.invalidateAndCancel() }
        let tmdb = TMDBClient(session: deviceSession, token: "configured-test-token", language: "en-GB")
        #expect(tmdb.isConfigured) // A missing token would hide accidental fallback.
        let router = LumeTitleMetadataRouter(tmdb: tmdb, proxy: proxy)
        for id in ids {
            let details = try #require(try await router.details(id: id, type: kind, source: source))
            #expect(!details.cast.isEmpty && details.overview?.isEmpty == false)
            #expect(details.posterPath != nil && details.logoPath != nil)
            #expect(details.videos.contains { $0.type == "Trailer" })
            #expect(details.proxyReceipt?.matches(source: source, tmdbID: id, language: "en-GB") == true)
            #expect(details.proxyReceipt?.tmdbAt == ISO8601DateFormatter().date(from: stamp))
        }
        #expect(StubURLProtocol.requests(forHost: host).count == 1 + ids.count)
    }
}

/// Only the injected device session uses this trap; no global registration or
/// real network access. Any device request fails even if its error is swallowed.
private final nonisolated class UnexpectedDeviceTMDBProtocol: URLProtocol {
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Issue.record("Complete proxy fixture unexpectedly triggered device TMDB")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}

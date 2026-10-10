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
}

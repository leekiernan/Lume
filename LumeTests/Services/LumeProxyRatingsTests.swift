import Foundation
@testable import Lume
import Testing

struct RatingsFreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_791_633_600) // 2026-10-10T12:00:00Z

    @Test func `window follows the title's age`() {
        #expect(RatingsFreshness.window(releaseDate: "2026-10-01", now: now) == RatingsFreshness.newRelease)
        #expect(RatingsFreshness.window(releaseDate: "2027-02-01", now: now) == RatingsFreshness.newRelease)
        #expect(RatingsFreshness.window(releaseDate: "2026-03-01 00:00:00", now: now) == RatingsFreshness.recent)
        #expect(RatingsFreshness.window(releaseDate: "1999-03-31", now: now) == RatingsFreshness.settled)
        #expect(RatingsFreshness.window(releaseDate: nil, now: now) == RatingsFreshness.recent)
        #expect(RatingsFreshness.window(releaseDate: "n/a", now: now) == RatingsFreshness.recent)
    }

    @Test func `a bare year is read as mid-year`() {
        #expect(RatingsFreshness.window(releaseDate: "2026", now: now) == RatingsFreshness.recent)
        #expect(RatingsFreshness.window(releaseDate: "1999", now: now) == RatingsFreshness.settled)
    }

    @Test func `future and expired stamps are stale`() {
        #expect(!RatingsFreshness.isFresh(nil, releaseDate: "1999-03-31", now: now))
        #expect(!RatingsFreshness.isFresh(now.addingTimeInterval(60), releaseDate: "1999-03-31", now: now))
        #expect(RatingsFreshness.isFresh(now.addingTimeInterval(-13 * 24 * 3600), releaseDate: "1999-03-31", now: now))
        #expect(!RatingsFreshness.isFresh(now.addingTimeInterval(-2 * 24 * 3600), releaseDate: "2026-10-01", now: now))
    }
}

/// Proxy ratings ride on the shared movie fixture: the real payload, with an
/// `mdblist` block and ratings stamp added in memory for The Matrix only.
@MainActor
struct LumeProxyRatingsTests {
    private final class ResourceAnchor {}

    private func movieFixture(ratingsAt: Date?, detailAt: Date) throws -> String {
        let name = "lume-metadata-batch-movie"
        let bundle = Bundle(for: ResourceAnchor.self)
        let sourceURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProxyMetadata/\(name).json")
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ProxyMetadata")
            ?? bundle.url(forResource: name, withExtension: "json") ?? sourceURL
        let data = try Data(contentsOf: url)
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try #require(root["items"] as? [[String: Any]])
        let stamp = ISO8601DateFormatter().string(from: detailAt)
        for index in items.indices {
            guard var meta = items[index]["lume_meta"] as? [String: Any] else { continue }
            meta["tmdb"] = stamp
            meta["artwork"] = stamp
            if items[index]["tmdb_id"] as? Int == 603, let ratingsAt {
                meta["ratings"] = ISO8601DateFormatter().string(from: ratingsAt)
                items[index]["mdblist"] = ["ratings": [
                    ["source": "imdb", "value": 8.7, "score": 87, "votes": 2_000_000],
                    ["source": "tomatoes", "value": 83],
                    ["source": "rogerebert", "value": 4],
                    ["source": "metacriticuser", "value": NSNull()]
                ]]
            }
            items[index]["lume_meta"] = meta
        }
        root["items"] = items
        let encoded = try JSONSerialization.data(withJSONObject: root)
        return try #require(String(data: encoded, encoding: .utf8))
    }

    private struct Harness {
        let router: LumeTitleMetadataRouter
        let source: LumeProxySource
        let mdbListKey: String
        let sessions: [URLSession]

        func mdbListRequests() -> Int {
            StubURLProtocol.requests(forHost: "api.mdblist.com").count {
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.value == mdbListKey } == true
            }
        }
    }

    private func harness(groups: String, body: String) throws -> Harness {
        let host = UUID().uuidString.lowercased() + ".example.com"
        let source = try #require(LumeProxySource(playlist: Playlist(name: "Proxy", serverURL: "https://\(host)", username: "test", password: "test")))
        StubURLProtocol.register(host: host, pathSuffix: "/capabilities",
                                 response: .init(body: #"{"v":1,"metadata":{"v":1,"max_batch_size":50,"languages":["en-GB"],"groups":\#(groups)}}"#))
        StubURLProtocol.register(host: host, pathSuffix: "/metadata", response: .init(body: body))
        let key = "key-" + UUID().uuidString
        StubURLProtocol.register(host: "api.mdblist.com", query: (name: "apikey", value: key),
                                 response: .init(body: #"{"ratings":[{"source":"imdb","value":6.1}]}"#))
        let session = StubURLProtocol.makeSession()
        let proxy = LumeMetadataClient(session: session, capabilities: LumeProxyCapabilityStore(session: session))
        let router = LumeTitleMetadataRouter(tmdb: TMDBClient(session: session, token: "configured-test-token", language: "en-GB"),
                                             proxy: proxy, mdbList: MDBListClient(session: session, key: key))
        return Harness(router: router, source: source, mdbListKey: key, sessions: [session])
    }

    @Test func `advertised fresh proxy ratings skip the device MDBList call`() async throws {
        let now = Date()
        let fetched = now.addingTimeInterval(-3600)
        let harness = try harness(groups: #"["tmdb","artwork","ratings"]"#, body: movieFixture(ratingsAt: fetched, detailAt: fetched))
        defer { harness.sessions.forEach { $0.invalidateAndCancel() } }

        let ratings = try #require(try await harness.router.ratings(id: 603, type: .movie, releaseDate: "1999-03-31", source: harness.source, now: now))
        #expect(ratings.ratings.map(\.source) == [.imdb, .rottenTomatoes])
        #expect(ratings.ratings.first?.value == "8.7/10")
        #expect(abs(ratings.fetchedAt.timeIntervalSince(fetched)) < 1)
        #expect(harness.mdbListRequests() == 0)

        // Detail and ratings share one batch read: the second is answered from cache.
        let details = try #require(try await harness.router.details(id: 603, type: .movie, source: harness.source))
        #expect(details.proxyRatings == ratings)
    }

    @Test func `unadvertised, missing or stale proxy ratings fall back to MDBList`() async throws {
        let now = Date()
        let recent = now.addingTimeInterval(-3600)
        let unadvertised = try harness(groups: #"["tmdb","artwork"]"#, body: movieFixture(ratingsAt: recent, detailAt: recent))
        defer { unadvertised.sessions.forEach { $0.invalidateAndCancel() } }
        let direct = try #require(try await unadvertised.router.ratings(id: 603, type: .movie, releaseDate: "1999-03-31", source: unadvertised.source, now: now))
        #expect(direct.ratings.first?.value == "6.1/10" && unadvertised.mdbListRequests() == 1)

        let missing = try harness(groups: #"["tmdb","artwork","ratings"]"#, body: movieFixture(ratingsAt: recent, detailAt: recent))
        defer { missing.sessions.forEach { $0.invalidateAndCancel() } }
        _ = try await missing.router.ratings(id: 372_058, type: .movie, releaseDate: "2016-08-26", source: missing.source, now: now)
        #expect(missing.mdbListRequests() == 1)

        // Two days old is fine for a 1999 film but stale for this week's release.
        let older = now.addingTimeInterval(-2 * 24 * 3600)
        let stale = try harness(groups: #"["tmdb","artwork","ratings"]"#, body: movieFixture(ratingsAt: older, detailAt: recent))
        defer { stale.sessions.forEach { $0.invalidateAndCancel() } }
        let settled = try await stale.router.ratings(id: 603, type: .movie, releaseDate: "1999-03-31", source: stale.source, now: now)
        #expect(settled?.ratings.first?.value == "8.7/10" && stale.mdbListRequests() == 0)
        let new = try await stale.router.ratings(id: 603, type: .movie, releaseDate: ISO8601DateFormatter().string(from: now).prefix(10).description,
                                                 source: stale.source, now: now)
        #expect(new?.ratings.first?.value == "6.1/10" && stale.mdbListRequests() == 1)
    }

    @Test func `stale proxy ratings are still returned without a device key`() async throws {
        let now = Date()
        let older = now.addingTimeInterval(-20 * 24 * 3600)
        let harness = try harness(groups: #"["tmdb","artwork","ratings"]"#, body: movieFixture(ratingsAt: older, detailAt: now.addingTimeInterval(-3600)))
        defer { harness.sessions.forEach { $0.invalidateAndCancel() } }
        let keyless = LumeTitleMetadataRouter(tmdb: harness.router.tmdb, proxy: harness.router.proxy, mdbList: MDBListClient(session: harness.sessions[0], key: nil))
        #expect(keyless.canFetchRatings(source: harness.source) && !keyless.canFetchRatings(source: nil))
        let ratings = try await keyless.ratings(id: 603, type: .movie, releaseDate: "1999-03-31", source: harness.source, now: now)
        #expect(ratings?.ratings.first?.value == "8.7/10")
        #expect(abs((ratings?.fetchedAt.timeIntervalSince(older)) ?? 99) < 1) // Old stamp kept, so the next open asks again.
    }
}

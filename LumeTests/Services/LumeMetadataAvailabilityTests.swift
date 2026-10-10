import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LumeMetadataAvailabilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func capabilities(_ json: String = #"{"v":1,"metadata":{"v":1,"max_batch_size":50}}"#) throws -> LumeProxyCapabilities {
        try JSONDecoder().decode(LumeProxyCapabilities.self, from: Data(json.utf8))
    }

    private func availability(_ json: String) throws -> LumeMetadataAvailability {
        try JSONDecoder().decode(LumeMetadataAvailability.self, from: Data(json.utf8))
    }

    @Test(arguments: [#"{"v":1,"tmdb":"2026-10-09T03:00:00Z"}"#,
                      #"{"v":1,"tmdb":"2026-10-09T03:00:00.123Z"}"#])
    func `stamps retain original source age and allow ISO timestamps with fractions`(_ json: String) throws {
        let stamps = try availability(json)
        let date = try #require(stamps.availableAt(for: .tmdb, capabilities: capabilities(), now: now))
        #expect(date < now.addingTimeInterval(-86400))
        #expect(try stamps.availableAt(for: .artwork, capabilities: capabilities(), now: now) == nil)
    }

    @Test(arguments: [#"{"v":2,"tmdb":"2026-10-09T03:00:00Z"}"#,
                      #"{"v":1,"tmdb":"2099-01-01T00:00:00Z"}"#,
                      #"{"v":1,"tmdb":"bad date"}"#,
                      #"{"v":1,"tmdb":true}"#])
    func `unknown versions and invalid or future stamps are not usable`(_ json: String) throws {
        #expect(try availability(json).availableAt(for: .tmdb, capabilities: capabilities(), now: now) == nil)
    }

    @Test func `catalogue stamps cannot grant an unadvertised capability`() throws {
        let stamps = try availability(#"{"v":1,"tmdb":"2026-10-09T03:00:00Z"}"#)
        #expect(try stamps.availableAt(for: .tmdb, capabilities: capabilities(#"{"v":1}"#), now: now) == nil)
    }

    @Test func `invalid group does not discard other usable groups`() throws {
        let stamps = try availability(#"{"v":1,"tmdb":7,"artwork":"2026-10-09T03:00:00Z","ratings":{}}"#)
        #expect(try stamps.availableAt(for: .tmdb, capabilities: capabilities(), now: now) == nil)
        #expect(try stamps.availableAt(for: .artwork, capabilities: capabilities(), now: now) != nil)
        #expect(try stamps.availableAt(for: .ratings, capabilities: capabilities(), now: now) == nil)
    }

    @Test(arguments: ["null", "[]", "true", #"{"v":"1"}"#])
    func `malformed optional extension does not break ordinary catalogue decoding`(_ extensionJSON: String) throws {
        let json = "{\"stream_id\":1,\"series_id\":2,\"name\":\"Title\",\"lume_meta\":\(extensionJSON)}"
        let movie = try FieldFixtures.decodeMovie(json)
        let series = try FieldFixtures.decodeSeries(json)
        #expect(movie.streamId == 1 && movie.name == "Title" && movie.lumeMeta == nil)
        #expect(series.seriesId == 2 && series.name == "Title" && series.lumeMeta == nil)
    }

    @Test func `importing availability never marks metadata artwork or ratings complete`() async throws {
        let container = try FieldFixtures.makeContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "movie", streamId: 1, name: "Title")
        let series = Series(id: "series", seriesId: 2, name: "Title")
        context.insert(movie)
        context.insert(series)
        try context.save()
        let json = #"""
        {"stream_id":1,"series_id":2,"name":"Title","tmdb":"123",
         "lume_meta":{"v":1,"tmdb":"2026-10-09T03:00:00Z","artwork":"2026-10-09T03:00:00Z","ratings":"2026-10-09T03:00:00Z"}}
        """#
        let manager = ContentSyncManager(modelContainer: container)
        try await manager.applyMovieFields(from: FieldFixtures.decodeMovie(json), to: movie, playlistPrefix: "p-")
        try await manager.applySeriesFields(from: FieldFixtures.decodeSeries(json), to: series, playlistPrefix: "p-")
        try context.save()
        #expect(movie.tmdbId == 123 && series.tmdbId == 123)
        #expect(movie.tmdbEnrichedAt == nil && movie.tmdbArtworkEnrichedAt == nil && movie.ratingsEnrichedAt == nil)
        #expect(series.tmdbEnrichedAt == nil && series.tmdbArtworkEnrichedAt == nil && series.ratingsEnrichedAt == nil)
    }
}

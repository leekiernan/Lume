import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct XtreamSeriesMetadataTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Series.self, Episode.self, Movie.self, CastMember.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContext(ModelContainer(for: schema, configurations: [configuration]))
    }

    private func info(_ json: String) throws -> XtreamSeriesInfo {
        try JSONDecoder().decode(XtreamSeriesInfo.self, from: Data(json.utf8))
    }

    private func catalogue(_ json: String) throws -> XtreamSeries {
        try JSONDecoder().decode(XtreamSeries.self, from: Data(json.utf8))
    }

    @Test func `series detail fills metadata without changing catalogue identity or user state`() throws {
        let context = try makeContext()
        let series = Series(id: "p-series-1", seriesId: 1, name: "Provider Show 4K", lastModified: "old", categoryId: "category")
        series.isFavorite = true
        series.tmdbEnrichedAt = nil
        context.insert(series)
        let metadata = try info(#"""
        {"name":"Other name","cover":"cover.jpg","plot":"Synopsis","cast":"Actor","director":"Director",
         "genre":"Drama","releaseDate":"2020-01-01","rating":"7.0","tmdb":"123","last_modified":"other"}
        """#)
        series.applyFetchedEpisodes(FetchedEpisodes(episodes: [], seriesInfo: metadata), into: context)

        #expect(series.cover == "cover.jpg" && series.plot == "Synopsis")
        #expect(series.cast == "Actor" && series.director == "Director" && series.genre == "Drama")
        #expect(series.releaseDate == "2020-01-01" && series.rating == "7.0")
        #expect(series.tmdbId == 123 && series.tmdb == "123")
        #expect(series.name == "Provider Show 4K" && series.categoryId == "category" && series.lastModified == "old")
        #expect(series.episodesFetchedLastModified == "old" && series.episodesFetchedAt != nil)
        #expect(series.isFavorite && series.tmdbEnrichedAt == nil)
    }

    @Test func `detail info only fills missing fields and preserves an existing match`() throws {
        let series = Series(id: "s", seriesId: 1, name: "Show", cover: "existing.jpg", plot: "Existing", genre: "TMDB genre", tmdb: "100")
        series.tmdbId = 100
        series.cast = "  "
        try series.applyProviderMetadata(info(#"{"cover":"other.jpg","plot":"Other","cast":"Actor","genre":"Other genre","tmdb":"200"}"#), fillMissing: true)

        #expect(series.cover == "existing.jpg" && series.plot == "Existing")
        #expect(series.cast == "Actor" && series.genre == "TMDB genre")
        #expect(series.tmdbId == 100 && series.tmdb == "100")
    }

    @Test func `sparse catalogue preserves detail metadata while supplied values can update it`() throws {
        let series = Series(id: "s", seriesId: 1, name: "Show")
        try series.applyProviderMetadata(info(#"""
        {"cover":"cover.jpg","plot":"Synopsis","cast":"Actor","director":"Director",
         "releaseDate":"2020-01-01","rating":"7.0","tmdb":"123"}
        """#), fillMissing: true)
        try series.applyProviderMetadata(catalogue(#"{"series_id":1,"cover":"","plot":null,"cast":"  ","director":"","tmdb":"0"}"#), fillMissing: false)

        #expect(series.cover == "cover.jpg" && series.plot == "Synopsis" && series.cast == "Actor")
        #expect(series.director == "Director" && series.releaseDate == "2020-01-01" && series.rating == "7.0")
        #expect(series.tmdbId == 123 && series.tmdb == "123")

        try series.applyProviderMetadata(catalogue(#"{"series_id":1,"cover":"updated.jpg","plot":"Updated","rating":"7"}"#), fillMissing: false)
        #expect(series.cover == "updated.jpg" && series.plot == "Updated" && series.rating == "7")
    }

    @Test func `unchanged series metadata does not dirty a saved model`() throws {
        let context = try makeContext()
        let series = Series(id: "s", seriesId: 1, name: "Show")
        let metadata = try catalogue(#"{"series_id":1,"cover":"cover.jpg","plot":"Synopsis","genre":"Drama","rating":"7","tmdb":"123"}"#)
        context.insert(series)
        series.applyProviderMetadata(metadata, fillMissing: false)
        try context.save()
        series.applyProviderMetadata(metadata, fillMissing: false)

        #expect(!context.hasChanges)
    }
}

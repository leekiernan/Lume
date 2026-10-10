import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TMDBFallbackTests {
    @Test func `repeated TMDB writes restore original provider genre and absent synopsis`() {
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        movie.genre = "Provider genre"
        applyMovieArtwork(TMDBTitleDetails(overview: "TMDB synopsis", voteAverage: 8, runtimeMinutes: 90, genreNames: ["Drama"],
                                           cast: [], similarIDs: [], videos: []), to: movie)
        applyMovieArtwork(TMDBTitleDetails(genreNames: ["Comedy"], cast: [], similarIDs: [], videos: []), to: movie)
        #expect(movie.genre == "Comedy" && movie.durationSecs == 5400 && movie.rating == 8)

        movie.restoreTMDBFallbacks()
        #expect(movie.genre == "Provider genre" && movie.plot == nil)
        #expect(movie.durationSecs == nil && movie.rating == 0 && movie.tmdbFallbackData == nil)
    }

    @Test func `provider edits after hydration survive restoration`() {
        let series = Series(id: "series", seriesId: 1, name: "Show")
        let details = TMDBTitleDetails(overview: "TMDB synopsis", voteAverage: 8, genreNames: ["Drama"],
                                       cast: [TMDBCastMember(tmdbPersonId: 7, name: "Actor", character: nil, profilePath: nil, order: 0)],
                                       similarIDs: [], videos: [])
        applySeriesArtwork(details, to: series)
        series.plot = "Provider edit"
        series.rating = "9"
        series.restoreTMDBFallbacks()
        #expect(series.plot == "Provider edit" && series.rating == "9")
        #expect(series.genre == nil && series.cast == nil)
    }

    @Test func `fallback provenance persists across contexts`() throws {
        let container = try FieldFixtures.makeContainer()
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        container.mainContext.insert(movie)
        movie.genre = "Provider genre"
        applyMovieArtwork(TMDBTitleDetails(genreNames: ["Drama"], cast: [], similarIDs: [], videos: []), to: movie)
        try container.mainContext.save()
        let reloaded = try #require(ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        reloaded.restoreTMDBFallbacks()
        #expect(reloaded.genre == "Provider genre")
    }

    @Test func `legacy shared metadata without provenance is preserved`() {
        let movie = Movie(id: "legacy", streamId: 1, name: "Movie", rating: 7)
        movie.plot = "Unknown source"
        movie.genre = "Unknown source"
        movie.durationSecs = 5400
        movie.restoreTMDBFallbacks()
        #expect(movie.plot == "Unknown source" && movie.genre == "Unknown source")
        #expect(movie.durationSecs == 5400 && movie.rating == 7)
    }
}

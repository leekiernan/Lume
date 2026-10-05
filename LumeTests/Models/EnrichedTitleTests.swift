import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct EnrichedTitleTests {
    @Test func `clearing metadata deletes cast but preserves poster and provider and user fields`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        let series = Series(id: "series", seriesId: 1, name: "Series")
        context.insert(movie)
        context.insert(series)
        let details = TMDBTitleDetails(posterPath: "/poster.jpg", backdropPath: "/backdrop.jpg", genreNames: ["Drama"],
                                       cast: [TMDBCastMember(tmdbPersonId: 1, name: "Actor", character: nil, profilePath: nil, order: 0)],
                                       similarIDs: [7], videos: [])
        applyMovieDetails(details, to: movie, context: context)
        applySeriesDetails(details, to: series, context: context)
        movie.isFavorite = true
        movie.watchProgress = 123
        movie.tmdbArtworkEnrichedAt = Date()
        series.tmdbArtworkEnrichedAt = Date()
        movie.clearCommonEnrichment(in: context)
        series.clearCommonEnrichment(in: context)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<CastMember>()) == 0)
        #expect(movie.posterPath == "/poster.jpg" && series.posterPath == "/poster.jpg")
        #expect(movie.backdropPath == nil && series.backdropPath == nil)
        #expect(movie.tmdbEnrichedAt == nil && series.tmdbEnrichedAt == nil)
        #expect(movie.tmdbArtworkEnrichedAt == nil && series.tmdbArtworkEnrichedAt == nil)
        #expect(movie.similarTMDBIds == nil && series.trailersData == nil)
        #expect(movie.isFavorite && movie.watchProgress == 123 && movie.genre == "Drama")
    }

    @Test func `common metadata roundtrips with the existing nil and blob conventions`() throws {
        try OnDiskCatalogStore.withContext { context in
            let movie = Movie(id: "movie", streamId: 1, name: "Movie")
            let series = Series(id: "series", seriesId: 1, name: "Series")
            context.insert(movie)
            context.insert(series)
            checkAccessors(movie)
            checkAccessors(series)
            try context.save()
            let check = ModelContext(context.container)
            let storedMovie = try #require(check.fetch(FetchDescriptor<Movie>()).first)
            let storedSeries = try #require(check.fetch(FetchDescriptor<Series>()).first)
            #expect(storedMovie.similarTitleIds == [1, 2])
            #expect(storedSeries.similarTitleIds == [1, 2])
            #expect(storedMovie.trailers == storedSeries.trailers)
            #expect(storedMovie.externalRatings == storedSeries.externalRatings)
        }
    }

    private func checkAccessors(_ title: some EnrichedTitle) {
        title.similarTitleIds = []
        #expect(title.similarTMDBIds == nil)
        title.similarTitleIds = [1, 2]
        title.trailers = [TitleVideo(key: "video", name: "Trailer", type: "Trailer")]
        title.externalRatings = [ExternalRating(source: .imdb, value: "8.5")]
        #expect(title.trailers.first?.key == "video")
        #expect(title.externalRatings.first?.value == "8.5")
    }

    @Test func `common artwork preserves provider fields and leaves cast and full freshness alone`() throws {
        let container = try makeTestContainer()
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        let series = Series(id: "series", seriesId: 1, name: "Series")
        container.mainContext.insert(movie)
        container.mainContext.insert(series)
        verifyArtwork(movie)
        verifyArtwork(series)
    }

    private func verifyArtwork(_ title: some EnrichedTitle) {
        title.plot = "Provider plot"
        title.posterPath = "/old.jpg"
        title.tmdbEnrichedAt = .distantPast
        let details = TMDBTitleDetails(backdropPath: "/backdrop.jpg", overview: "TMDB plot", genreNames: ["Drama"],
                                       cast: [], similarIDs: [7], videos: [])
        title.applyCommonArtwork(details)
        #expect(title.plot == "Provider plot")
        #expect(title.posterPath == "/old.jpg")
        #expect(title.backdropPath == "/backdrop.jpg" && title.genre == "Drama")
        #expect(title.tmdbEnrichedAt == .distantPast && title.tmdbArtworkEnrichedAt != nil)
        #expect(title.castMembers.isEmpty)
    }
}

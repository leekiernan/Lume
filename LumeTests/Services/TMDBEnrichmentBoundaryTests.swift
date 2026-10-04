import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct TMDBEnrichmentBoundaryTests {
    @Test func `scalar enrichment in another context preserves displayed movie and series cast`() throws {
        try OnDiskCatalogStore.withContext { viewContext in
            let movie = Movie(id: "movie", streamId: 1, name: "Movie")
            let series = Series(id: "series", seriesId: 1, name: "Series")
            viewContext.insert(movie)
            viewContext.insert(series)
            applyMovieDetails(details(name: "Original"), to: movie, context: viewContext)
            applySeriesDetails(details(name: "Original"), to: series, context: viewContext)
            let originalStamp = Date(timeIntervalSince1970: 100)
            movie.tmdbEnrichedAt = originalStamp
            series.tmdbEnrichedAt = originalStamp
            try viewContext.save()
            let heldMovieCast = movie.castMembers
            let heldSeriesCast = series.castMembers
            let heldIDs = Set((heldMovieCast + heldSeriesCast).map(\.persistentModelID))

            let artworkContext = ModelContext(viewContext.container)
            artworkContext.autosaveEnabled = false
            let storedMovie = try #require(artworkContext.fetch(FetchDescriptor<Movie>()).first)
            let storedSeries = try #require(artworkContext.fetch(FetchDescriptor<Series>()).first)
            let fresh = details(name: "Replacement", poster: "/fresh.jpg")
            applyMovieArtwork(fresh, to: storedMovie)
            applySeriesArtwork(fresh, to: storedSeries)
            try artworkContext.save()

            let checkContext = ModelContext(viewContext.container)
            let casts = try checkContext.fetch(FetchDescriptor<CastMember>())
            #expect(Set(casts.map(\.persistentModelID)) == heldIDs)
            #expect(heldMovieCast.map(\.name) == ["Original"])
            #expect(heldSeriesCast.map(\.name) == ["Original"])
            let checkedMovie = try #require(checkContext.fetch(FetchDescriptor<Movie>()).first)
            let checkedSeries = try #require(checkContext.fetch(FetchDescriptor<Series>()).first)
            #expect(checkedMovie.posterPath == "/fresh.jpg")
            #expect(checkedSeries.posterPath == "/fresh.jpg")
            #expect(checkedMovie.tmdbEnrichedAt == originalStamp)
            #expect(checkedSeries.tmdbEnrichedAt == originalStamp)
            #expect(TMDBFreshness.isFresh(checkedMovie.tmdbArtworkEnrichedAt))
            #expect(TMDBFreshness.isFresh(checkedSeries.tmdbArtworkEnrichedAt))
        }
    }

    @Test func `partial enrichment negative caches missing artwork without completing details`() throws {
        let container = try makeTestContainer()
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        let series = Series(id: "series", seriesId: 1, name: "Series")
        movie.tmdbId = 123
        series.tmdbId = 456
        container.mainContext.insert(movie)
        container.mainContext.insert(series)
        let missing = TMDBTitleDetails(genreNames: [], cast: [], similarIDs: [], videos: [])
        applyMovieArtwork(missing, to: movie)
        applySeriesArtwork(missing, to: series)
        #expect(movie.tmdbEnrichedAt == nil)
        #expect(series.tmdbEnrichedAt == nil)
        #expect(!SectionFeed.heroNeedsArtwork(backdropPath: nil, posterPath: nil, posterCheckedAt: movie.posterCheckedAt,
                                              logoPath: nil, enrichedAt: movie.tmdbArtworkEnrichedAt))
        #expect(ContinueWatchingArtworkRequest(.movie(movie)) == nil)
        #expect(ContinueWatchingArtworkRequest(.series(series)) == nil)
        #expect(detailNeedsTMDBFetch(tmdbId: movie.tmdbId, enrichedAt: movie.tmdbEnrichedAt) == TMDBClient.shared.isConfigured)

        movie.tmdbArtworkEnrichedAt = .distantPast
        series.tmdbArtworkEnrichedAt = .distantPast
        #expect(ContinueWatchingArtworkRequest(.movie(movie)) != nil)
        #expect(ContinueWatchingArtworkRequest(.series(series)) != nil)
    }

    @Test func `poster only recovery does not imply backdrop and logo freshness`() {
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        movie.tmdbId = 123
        movie.posterPath = "/poster.jpg"
        movie.posterCheckedAt = .now
        #expect(ContinueWatchingArtworkRequest(.movie(movie)) != nil)
        #expect(SectionFeed.heroNeedsArtwork(backdropPath: nil, posterPath: movie.posterPath, posterCheckedAt: movie.posterCheckedAt,
                                             logoPath: nil, enrichedAt: movie.tmdbArtworkEnrichedAt))
    }

    @Test func `full details still replace cast and stamp both freshness lanes`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        let series = Series(id: "series", seriesId: 1, name: "Series")
        context.insert(movie)
        context.insert(series)
        applyMovieDetails(details(name: "Original"), to: movie, context: context)
        applySeriesDetails(details(name: "Original"), to: series, context: context)
        try context.save()
        applyMovieDetails(details(name: "Replacement"), to: movie, context: context)
        applySeriesDetails(details(name: "Replacement"), to: series, context: context)
        try context.save()
        #expect(movie.castMembers.map(\.name) == ["Replacement"])
        #expect(series.castMembers.map(\.name) == ["Replacement"])
        #expect(try context.fetchCount(FetchDescriptor<CastMember>()) == 2)
        #expect(TMDBFreshness.isFresh(movie.tmdbEnrichedAt))
        #expect(TMDBFreshness.isFresh(series.tmdbEnrichedAt))
        #expect(TMDBFreshness.isFresh(movie.tmdbArtworkEnrichedAt))
        #expect(TMDBFreshness.isFresh(series.tmdbArtworkEnrichedAt))
    }

    private func details(name: String, poster: String? = nil) -> TMDBTitleDetails {
        TMDBTitleDetails(posterPath: poster, genreNames: [],
                         cast: [TMDBCastMember(tmdbPersonId: name == "Original" ? 1 : 2, name: name, character: nil, profilePath: nil, order: 0)],
                         similarIDs: [], videos: [])
    }
}

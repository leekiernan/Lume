import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct StorageManagerTests {
    @Test func `gatherStats counts every catalog type`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        context.insert(Movie(id: "m1", streamId: 1, name: "A"))
        context.insert(Movie(id: "m2", streamId: 2, name: "B"))
        let show = Series(id: "s1", seriesId: 1, name: "Show")
        context.insert(show)
        context.insert(Episode(
            id: "e1", episodeId: "1", title: "Pilot", containerExtension: "mkv",
            seasonNum: 1, episodeNum: 1, series: show
        ))
        context.insert(LiveStream(id: "c1", streamId: 1, name: "Channel"))
        try context.save()

        let stats = await StorageManager.gatherStats(in: context)

        #expect(stats.movieCount == 2)
        #expect(stats.seriesCount == 1)
        #expect(stats.episodeCount == 1)
        #expect(stats.channelCount == 1)
    }

    @Test func `clearMetadataEnrichment resets enrichment but keeps the title`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let movie = Movie(id: "m1", streamId: 1, name: "Keep Me")
        movie.backdropPath = "/backdrop.jpg"
        movie.logoPath = "/logo.png"
        movie.tagline = "A tagline"
        movie.contentRating = "PG-13"
        movie.tmdbEnrichedAt = Date(timeIntervalSince1970: 1)
        movie.tmdbArtworkEnrichedAt = Date()
        movie.similarTMDBIds = [1, 2, 3]
        movie.trailers = [TitleVideo(key: "abc", name: "Trailer", type: "Trailer")]
        movie.imdbId = "tt1234567"
        movie.externalRatings = [ExternalRating(source: .imdb, value: "8.0/10")]
        movie.ratingsEnrichedAt = Date(timeIntervalSince1970: 1)
        movie.collectionId = 99
        movie.collectionName = "Series Collection"
        movie.isFavorite = true
        movie.watchProgress = 0.4
        context.insert(movie)
        context.insert(CastMember(id: "m1-cast-0", tmdbPersonId: 5, name: "Actor", order: 0, movie: movie))
        try context.save()

        await StorageManager.clearMetadataEnrichment(container: container)

        // Verify against a fresh context: the clear ran on its own background
        // context, and the main context's registered objects may not have
        // merged the change yet.
        let verifyContext = ModelContext(container)
        let refetched = try #require(
            try verifyContext.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == "m1" })).first
        )
        // Title and user data survive.
        #expect(refetched.name == "Keep Me")
        #expect(refetched.isFavorite == true)
        #expect(refetched.watchProgress == 0.4)
        // Enrichment is gone.
        #expect(refetched.backdropPath == nil)
        #expect(refetched.logoPath == nil)
        #expect(refetched.tagline == nil)
        #expect(refetched.contentRating == nil)
        #expect(refetched.tmdbEnrichedAt == nil)
        #expect(refetched.tmdbArtworkEnrichedAt == nil)
        #expect(refetched.similarTMDBIds == nil)
        #expect(refetched.trailers.isEmpty)
        #expect(refetched.imdbId == nil)
        #expect(refetched.externalRatings.isEmpty)
        #expect(refetched.ratingsEnrichedAt == nil)
        #expect(refetched.collectionId == nil)
        #expect(refetched.collectionName == nil)
        #expect(refetched.castMembers.isEmpty)

        let remainingCast = try verifyContext.fetch(FetchDescriptor<CastMember>())
        #expect(remainingCast.isEmpty)
    }

    /// Series enrichment is cleared by its own overload. `similarTMDBIds` is
    /// optional on both models, and nil — not [] — is the cleared state, so a
    /// row that has been reset costs nothing to store.
    @Test func `clearMetadataEnrichment resets a series too`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let show = Series(id: "s1", seriesId: 1, name: "Keep Me Too")
        show.tagline = "A tagline"
        show.tmdbEnrichedAt = Date(timeIntervalSince1970: 1)
        show.tmdbArtworkEnrichedAt = Date()
        show.similarTMDBIds = [4, 5, 6]
        show.isFavorite = true
        context.insert(show)
        try context.save()

        await StorageManager.clearMetadataEnrichment(container: container)

        let verifyContext = ModelContext(container)
        let refetched = try #require(
            try verifyContext.fetch(FetchDescriptor<Series>(predicate: #Predicate { $0.id == "s1" })).first
        )
        #expect(refetched.name == "Keep Me Too")
        #expect(refetched.isFavorite == true)
        #expect(refetched.tagline == nil)
        #expect(refetched.tmdbEnrichedAt == nil)
        #expect(refetched.tmdbArtworkEnrichedAt == nil)
        #expect(refetched.similarTMDBIds == nil)
    }

    @Test func `clear metadata reaches artwork-only rows and rearms artwork requests`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumeArtworkClear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = OnDiskCatalogStore.catalogSchema
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("catalog.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = container.mainContext
        let movie = Movie(id: "artwork-movie", streamId: 1, name: "Movie")
        let series = Series(id: "artwork-series", seriesId: 1, name: "Series")
        context.insert(movie)
        context.insert(series)
        movie.tmdbId = 123
        series.tmdbId = 456
        seedArtworkOnly(movie)
        seedArtworkOnly(series)
        movie.isFavorite = true
        movie.watchProgress = 123
        let untouched = Movie(id: "provider-only", streamId: 2, name: "Provider")
        untouched.backdropPath = "/provider.jpg"
        context.insert(untouched)
        try context.save()
        #expect(ContinueWatchingArtworkRequest(.movie(movie)) == nil)
        #expect(ContinueWatchingArtworkRequest(.series(series)) == nil)

        await StorageManager.clearMetadataEnrichment(container: container)

        let verify = ModelContext(container)
        let storedMovie = try #require(verify.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == "artwork-movie" })).first)
        let storedSeries = try #require(verify.fetch(FetchDescriptor<Series>()).first)
        for title in [storedMovie as any EnrichedTitle, storedSeries as any EnrichedTitle] {
            #expect(title.tmdbArtworkEnrichedAt == nil)
            #expect(title.tmdbEnrichedAt == nil && title.ratingsEnrichedAt == nil)
            #expect(title.backdropPath == nil && title.logoPath == nil)
            #expect(title.posterPath == "/poster.jpg" && title.plot == "Provider plot")
        }
        #expect(storedMovie.isFavorite && storedMovie.watchProgress == 123)
        #expect(ContinueWatchingArtworkRequest(.movie(storedMovie)) != nil)
        #expect(ContinueWatchingArtworkRequest(.series(storedSeries)) != nil)
        let storedProvider = try #require(verify.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == "provider-only" })).first)
        #expect(storedProvider.backdropPath == "/provider.jpg")
    }

    private func seedArtworkOnly(_ title: some EnrichedTitle) {
        title.backdropPath = "/backdrop.jpg"
        title.logoPath = "/logo.png"
        title.posterPath = "/poster.jpg"
        title.plot = "Provider plot"
        title.tmdbArtworkEnrichedAt = Date()
        #expect(title.tmdbEnrichedAt == nil && title.ratingsEnrichedAt == nil)
    }

    /// The language-change invalidation only re-arms enrichment; the cached
    /// metadata stays until the re-fetch replaces it.
    @Test func `invalidateTMDBEnrichment clears only the enrichment stamp`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext

        let movie = Movie(id: "m1", streamId: 1, name: "Movie")
        movie.tagline = "Kept"
        movie.tmdbEnrichedAt = Date(timeIntervalSince1970: 1)
        movie.ratingsEnrichedAt = Date(timeIntervalSince1970: 2)
        context.insert(movie)
        let show = Series(id: "s1", seriesId: 1, name: "Show")
        show.backdropPath = "/kept.jpg"
        show.tmdbEnrichedAt = Date(timeIntervalSince1970: 1)
        context.insert(show)
        try context.save()

        await StorageManager.invalidateTMDBEnrichment(container: container)

        let verifyContext = ModelContext(container)
        let refetchedMovie = try #require(try verifyContext.fetch(FetchDescriptor<Movie>()).first)
        #expect(refetchedMovie.tmdbEnrichedAt == nil)
        #expect(refetchedMovie.tagline == "Kept")
        #expect(refetchedMovie.ratingsEnrichedAt == Date(timeIntervalSince1970: 2))
        let refetchedShow = try #require(try verifyContext.fetch(FetchDescriptor<Series>()).first)
        #expect(refetchedShow.tmdbEnrichedAt == nil)
        #expect(refetchedShow.backdropPath == "/kept.jpg")
    }
}

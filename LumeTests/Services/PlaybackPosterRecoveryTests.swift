import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct PlaybackPosterRecoveryTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Movie.self, Series.self, Episode.self, CastMember.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @Test func `synced episode resolves the series portrait independently of its still`() async throws {
        let container = try container()
        let context = ModelContext(container)
        let series = Series(id: "series", seriesId: 10, name: "Series")
        series.posterPath = "/portrait.jpg"
        let episode = Episode(id: "episode", episodeId: "11", title: "Pilot", containerExtension: "mp4",
                              seasonNum: 1, episodeNum: 1, series: series)
        episode.movieImage = "https://provider.example/still.jpg"
        context.insert(series)
        context.insert(episode)
        try context.save()
        let source = try #require(await PosterArtworkRecovery(container: container).playbackSource(for: .episode(episode.id)))
        #expect(source.request.kind == .series)
        #expect(source.request.id == series.id)
        #expect(source.url?.absoluteString == "https://image.tmdb.org/t/p/w500/portrait.jpg")
        #expect(episode.movieImage == "https://provider.example/still.jpg")
    }

    @Test func `local playback accepts provider portraits without a relay allowlist`() async throws {
        let container = try container()
        let context = ModelContext(container)
        let series = Series(id: "series", seriesId: 10, name: "Series", cover: "https://image.tmdb.org/t/p/w500/cover.jpg")
        let episode = Episode(id: "episode", episodeId: "11", title: "Pilot", containerExtension: "mp4",
                              seasonNum: 1, episodeNum: 1, series: series)
        context.insert(series)
        context.insert(episode)
        try context.save()
        let recovery = PosterArtworkRecovery(container: container)
        #expect(await recovery.playbackSource(for: .episode(episode.id))?.url?.absoluteString == series.cover)
        series.cover = "https://provider.example/private/cover.jpg"
        try context.save()
        #expect(await recovery.playbackSource(for: .episode(episode.id))?.url?.absoluteString == series.cover)
        series.cover = "http://provider.example/cover.jpg"
        try context.save()
        #expect(await recovery.playbackSource(for: .episode(episode.id))?.url?.absoluteString == series.cover)
        series.cover = "file:///private/cover.jpg"
        try context.save()
        #expect(await recovery.playbackSource(for: .episode(episode.id))?.url == nil)
        #expect(await recovery.playbackSource(for: .episode(episode.id))?.request.id == series.id)
        #expect(await recovery.playbackSource(for: .live("channel")) == nil)
        #expect(await recovery.playbackSource(for: .episode("deleted")) == nil)
    }

    @Test func `recovery reads enrichment saved after the playable snapshot was created`() async throws {
        let container = try container()
        let context = ModelContext(container)
        let series = Series(id: "series", seriesId: 10, name: "Series")
        let episode = Episode(id: "episode", episodeId: "11", title: "Pilot", containerExtension: "mp4",
                              seasonNum: 1, episodeNum: 1, series: series)
        context.insert(series)
        context.insert(episode)
        try context.save()
        let playlist = Playlist(name: "Test", serverURL: "http://example.com", username: "user", password: "pass")
        let snapshot = try #require(PlayableMedia.from(episode: episode, playlist: playlist))
        #expect(snapshot.seriesPosterURL == nil)
        series.posterPath = "/newly-enriched.jpg"
        try context.save()
        let source = try #require(await PosterArtworkRecovery(container: container).playbackSource(for: snapshot.contentRef))
        #expect(source.url?.absoluteString == "https://image.tmdb.org/t/p/w500/newly-enriched.jpg")
        #expect(snapshot.seriesPosterURL == nil)
        #expect(snapshot.startTime == 0)
    }

    @Test func `movie playback prefers stored portrait and falls back to provider artwork`() async throws {
        let container = try container()
        let context = ModelContext(container)
        let movie = Movie(id: "movie", streamId: 20, name: "Movie")
        movie.posterPath = "/movie-poster.jpg"
        movie.streamIcon = "https://provider.example/movie.jpg"
        context.insert(movie)
        try context.save()
        let recovery = PosterArtworkRecovery(container: container)
        let source = try #require(await recovery.playbackSource(for: .movie(movie.id)))
        #expect(source.request.kind == .movie)
        #expect(source.url?.absoluteString == "https://image.tmdb.org/t/p/w500/movie-poster.jpg")
        movie.posterPath = nil
        try context.save()
        #expect(await recovery.playbackSource(for: .movie(movie.id))?.url?.absoluteString == movie.streamIcon)
        #expect(await recovery.playbackSource(for: .movie("deleted")) == nil)
    }
}

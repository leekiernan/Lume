import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState, .trackerIdentity(.trakt), .trackerIdentity(.simkl))
struct WatchStateResetImportTests {
    private let oldDate = "2020-01-01T00:00:00Z"

    @Test func `old completion and pause cannot resurrect a reset movie`() throws {
        let context = try ModelContext(makeTestContainer())
        let movie = Movie(id: UUID().uuidString, streamId: 1, name: "Movie")
        movie.tmdbId = 100
        movie.durationSecs = 600
        movie.watchProgress = 120
        movie.lastWatchedDate = .now
        context.insert(movie)
        movie.setWatched(false)
        try context.save()

        let trakt = TraktWatchedMovie(movie: .init(ids: TraktIDs(tmdb: 100, trakt: nil)), lastWatchedAt: oldDate)
        let simkl = SimklWatchedMovie(status: "completed", lastWatchedAt: oldDate, movie: .init(ids: SimklWatchedIDs(tmdb: 100)))
        let pause = TraktPlaybackItem(progress: 50, pausedAt: oldDate, movie: trakt.movie, show: nil, episode: nil)
        #expect(TraktWatchedImporter.apply(movies: [trakt], shows: [], in: context).moviesMarked == 0)
        #expect(SimklWatchedImporter.apply(movies: [simkl], shows: [], in: context).moviesMarked == 0)
        #expect(TraktPlaybackImporter.apply([pause], in: context) == 0)
        #expect(!movie.isWatched && movie.watchProgress == 0)
        #expect(movie.lastWatchedDate == nil)

        // A real later play elsewhere is not blocked forever by the reset.
        let newer = ISO8601DateFormatter().string(from: .now.addingTimeInterval(60))
        let newPause = TraktPlaybackItem(progress: 50, pausedAt: newer, movie: trakt.movie, show: nil, episode: nil)
        #expect(TraktPlaybackImporter.apply([newPause], in: context) == 1)
        #expect(movie.watchProgress == 300)
    }

    @Test func `old episode imports cannot restore cleared parent recency`() throws {
        let (context, series, episode) = try makeEpisode()
        episode.setWatched(false)
        try context.save()

        let trakt = TraktWatchedShow(show: .init(ids: TraktIDs(tmdb: 300, trakt: nil)), seasons: [
            .init(number: 1, episodes: [.init(number: 1, lastWatchedAt: oldDate)])
        ])
        let simkl = SimklWatchedShow(show: .init(ids: SimklWatchedIDs(tmdb: 300)), seasons: [
            .init(number: 1, episodes: [.init(number: 1, lastWatchedAt: oldDate)])
        ])
        let pause = TraktPlaybackItem(progress: 50, pausedAt: oldDate, movie: nil, show: trakt.show, episode: .init(season: 1, number: 1))

        #expect(TraktWatchedImporter.apply(movies: [], shows: [trakt], in: context).episodesMarked == 0)
        #expect(SimklWatchedImporter.apply(movies: [], shows: [simkl], in: context).episodesMarked == 0)
        #expect(TraktPlaybackImporter.apply([pause], in: context) == 0)
        #expect(!episode.isWatched && episode.watchProgress == 0)
        #expect(episode.lastWatchedDate == nil)
        #expect(series.lastWatchedDate == nil)
    }

    @Test func `an undated remote completion cannot undo an explicit reset`() throws {
        let context = try ModelContext(makeTestContainer())
        let movie = Movie(id: UUID().uuidString, streamId: 1, name: "Movie")
        movie.tmdbId = 100
        context.insert(movie)
        movie.setWatched(false)
        try context.save()

        #expect(TraktWatchedImporter.apply(movies: [
            .init(movie: .init(ids: TraktIDs(tmdb: 100, trakt: nil)), lastWatchedAt: nil)
        ], shows: [], in: context).moviesMarked == 0)
        #expect(SimklWatchedImporter.apply(movies: [
            .init(status: "completed", lastWatchedAt: nil, movie: .init(ids: SimklWatchedIDs(tmdb: 100)))
        ], shows: [], in: context).moviesMarked == 0)
    }

    @Test func `a later remote episode completion can follow a reset and a rewatch advances recency`() throws {
        let (_, series, episode) = try makeEpisode()
        episode.setWatched(false)
        let newer = Date.now.addingTimeInterval(60)

        #expect(TrackerEpisodeHistory.applyCompletion(newer, to: episode, profileID: ActiveProfileStore.current))
        series.refreshWatchRecency(onlyAdvancing: true)
        #expect(episode.isWatched && episode.watchProgress == 600)
        #expect(series.lastWatchedDate == newer)

        let rewatch = newer.addingTimeInterval(60)
        #expect(!TrackerEpisodeHistory.applyCompletion(rewatch, to: episode, profileID: ActiveProfileStore.current))
        series.refreshWatchRecency(onlyAdvancing: true)
        #expect(series.lastWatchedDate == rewatch)
    }

    private func makeEpisode() throws -> (ModelContext, Series, Episode) {
        let context = try ModelContext(makeTestContainer())
        let series = Series(id: UUID().uuidString, seriesId: 1, name: "Show")
        series.tmdbId = 300
        context.insert(series)
        let episode = Episode(id: UUID().uuidString, episodeId: "1", title: "Episode", containerExtension: "mkv", seasonNum: 1, episodeNum: 1, series: series)
        episode.durationSecs = 600
        episode.watchProgress = 120
        episode.lastWatchedDate = .now
        series.lastWatchedDate = episode.lastWatchedDate
        context.insert(episode)
        try context.save()
        return (context, series, episode)
    }
}

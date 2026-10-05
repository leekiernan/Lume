import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState)
struct MediaWatchStateTests {
    @Test func `manual resets send unwatched intent to every tracker`() throws {
        let (context, _, episodes) = try makeSeries(count: 1)
        let movie = Movie(id: UUID().uuidString, streamId: 1, name: "Movie")
        movie.watchProgress = 120
        episodes[0].watchProgress = 120
        context.insert(movie)
        let first = HistorySpy(), second = HistorySpy()

        MediaWatchState.setWatched(false, movie: movie, in: context, trackers: [first, second])
        MediaWatchState.setWatched(false, episode: episodes[0], in: context, trackers: [first, second])

        for tracker in [first, second] {
            #expect(tracker.movieStates == [false])
            #expect(tracker.episodeStates == [false])
        }
        #expect(!context.hasChanges)
        #expect(movie.watchProgress == 0)
        #expect(episodes[0].watchProgress == 0)
    }

    @Test(arguments: [false, true])
    func `reset removes partial and finished movies from both watching rails`(finished: Bool) throws {
        let context = try ModelContext(makeTestContainer())
        let movie = Movie(id: UUID().uuidString, streamId: 1, name: "Movie")
        movie.durationSecs = 600
        movie.watchProgress = finished ? 600 : 120
        movie.isWatched = finished
        movie.lastWatchedDate = .now
        movie.isFavorite = true
        context.insert(movie)
        try context.save()
        RecentResumePoints.record(120, for: .movie(movie.id))

        movie.setWatched(false)
        try context.save()

        #expect(!movie.isWatched)
        #expect(movie.watchProgress == 0)
        #expect(movie.lastWatchedDate == nil)
        #expect(movie.isFavorite)
        #expect(ContentClearLedger.shared.ids.contains(movie.id))
        #expect(RecentResumePoints.start(for: .movie(movie.id), stored: 0, storedAt: nil, isWatched: false, duration: 600) == 0)
        for finished in [false, true] {
            #expect(try context.fetch(HomeQuery.watchedMovies(playlistPrefix: "", excludedCategoryIDs: [], finished: finished)).isEmpty)
        }
        let persisted = try #require(ModelContext(context.container).fetch(FetchDescriptor<Movie>()).first)
        #expect(persisted.watchProgress == 0)
        #expect(persisted.lastWatchedDate == nil)
    }

    @Test func `reset of the only played episode clears series recency`() throws {
        let (context, series, episodes) = try makeSeries(count: 1)
        let episode = episodes[0]
        episode.watchProgress = 120
        episode.lastWatchedDate = .now
        series.lastWatchedDate = episode.lastWatchedDate
        RecentResumePoints.record(120, for: .episode(episode.id))

        episode.setWatched(false)
        try context.save()

        #expect(!episode.isWatched)
        #expect(episode.watchProgress == 0)
        #expect(episode.lastWatchedDate == nil)
        #expect(series.lastWatchedDate == nil)
        #expect(ContentClearLedger.shared.ids.isSuperset(of: [episode.id, series.id]))
        #expect(RecentResumePoints.position(for: .episode(episode.id), stored: 120, storedAt: nil) == 0)
        #expect(try context.fetch(HomeQuery.watchedSeries(playlistPrefix: "", excludedCategoryIDs: [])).isEmpty)
    }

    @Test func `reset preserves other episode history and its series recency`() throws {
        let (_, series, episodes) = try makeSeries(count: 2)
        let earlier = episodes[0]
        earlier.isWatched = true
        earlier.watchProgress = 600
        earlier.lastWatchedDate = .now.addingTimeInterval(-3600)
        let current = episodes[1]
        current.watchProgress = 120
        current.lastWatchedDate = .now
        series.lastWatchedDate = current.lastWatchedDate

        current.setWatched(false)

        #expect(earlier.isWatched)
        #expect(earlier.watchProgress == 600)
        #expect(series.lastWatchedDate == earlier.lastWatchedDate)
        #expect(SeriesEpisodeProgress.markers(in: episodes).furthestInProgress == nil)
    }

    @Test func `mark watched still finishes partial content and updates recency`() throws {
        let (context, series, episodes) = try makeSeries(count: 1)
        let movie = Movie(id: UUID().uuidString, streamId: 1, name: "Movie")
        movie.durationSecs = 600
        context.insert(movie)
        movie.setWatched(true)
        episodes[0].setWatched(true)

        #expect(movie.isWatched && movie.watchProgress == 600)
        #expect(movie.lastWatchedDate != nil)
        #expect(episodes[0].isWatched && episodes[0].watchProgress == 600)
        #expect(series.lastWatchedDate == episodes[0].lastWatchedDate)
    }

    @Test func `a queued playback boundary cannot resurrect a later reset`() async throws {
        let context = try ModelContext(makeTestContainer())
        let movie = Movie(id: UUID().uuidString, streamId: 1, name: "Movie")
        context.insert(movie)
        try context.save()
        let boundary = Date.now.addingTimeInterval(-60)
        movie.setWatched(false)
        try context.save()
        let writer = WatchProgressWriter(container: context.container)

        await writer.record(ref: .movie(movie.id), progress: 120, duration: 600, recordedAt: boundary)
        await writer.markWatched(ref: .movie(movie.id), duration: 600, recordedAt: boundary)

        let persisted = try #require(ModelContext(context.container).fetch(FetchDescriptor<Movie>()).first)
        #expect(persisted.watchProgress == 0)
        #expect(persisted.lastWatchedDate == nil)
    }

    private func makeSeries(count: Int) throws -> (ModelContext, Series, [Episode]) {
        let context = try ModelContext(makeTestContainer())
        let series = Series(id: UUID().uuidString, seriesId: 1, name: "Show")
        context.insert(series)
        let episodes = (1 ... count).map { number in
            let episode = Episode(id: UUID().uuidString, episodeId: "\(number)", title: "Episode", containerExtension: "mkv", seasonNum: 1, episodeNum: number, series: series)
            episode.durationSecs = 600
            context.insert(episode)
            return episode
        }
        try context.save()
        return (context, series, episodes)
    }

    private final class HistorySpy: TrackerHistorySynchronizing {
        var movieStates: [Bool] = []
        var episodeStates: [Bool] = []
        func syncWatched(movie _: Movie, watched: Bool) {
            movieStates.append(watched)
        }

        func syncWatched(episode _: Episode, watched: Bool) {
            episodeStates.append(watched)
        }

        func retryPendingMutations() {}
    }
}

struct MediaWatchedMenuTests {
    @Test(arguments: [0.1, 120.0, 599.0])
    func `incomplete content offers reset as well as mark watched`(progress: Double) {
        let state = MediaWatchedMenu.State(isWatched: false, progress: progress, lastWatchedDate: nil)
        #expect(!state.isWatched)
        #expect(state.canMarkUnwatched)
    }

    @Test func `finished or dated content can be reset even without progress`() {
        #expect(MediaWatchedMenu.State(isWatched: true, progress: 0, lastWatchedDate: nil).canMarkUnwatched)
        #expect(MediaWatchedMenu.State(isWatched: false, progress: 0, lastWatchedDate: .now).canMarkUnwatched)
        #expect(!MediaWatchedMenu.State(isWatched: false, progress: 0, lastWatchedDate: nil).canMarkUnwatched)
    }
}

struct WatchHistoryClearsTests {
    @Test func `reset guard persists and isolates profiles and content`() throws {
        let name = "WatchHistoryClearsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID(), second = UUID()
        let date = Date.now
        WatchHistoryClears(defaults: defaults).record("movie", at: date, profileID: first)
        let reloaded = WatchHistoryClears(defaults: defaults)
        #expect(!reloaded.allows(nil, for: "movie", profileID: first))
        #expect(!reloaded.allows(date, for: "movie", profileID: first))
        #expect(reloaded.allows(date.addingTimeInterval(1), for: "movie", profileID: first))
        #expect(reloaded.allows(nil, for: "movie", profileID: second))
        #expect(reloaded.allows(nil, for: "other", profileID: first))
        reloaded.purge(profileID: first)
        #expect(reloaded.allows(nil, for: "movie", profileID: first))
    }
}

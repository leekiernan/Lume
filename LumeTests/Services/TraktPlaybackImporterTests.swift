//
//  TraktPlaybackImporterTests.swift
//  LumeTests
//
//  Paused playback from Trakt lands in Continue Watching — position and date —
//  without overwriting anything newer on this device or reopening a title
//  finished here.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.serialized, .globalState, .trackerIdentity(.trakt))
struct TraktPlaybackImporterTests {
    init() {
        // Unfetched episodes park their pause in this store; start each test
        // from empty.
        TraktPendingWatchedStore.clearAll()
        TraktPendingWatchedStore.resetCacheForTesting()
    }

    private let paused = "2026-09-20T20:00:00.000Z"
    private var pausedDate: Date {
        TraktWatchedImporter.parse(paused)!
    }

    private func makeContext() throws -> ModelContext {
        try ModelContext(makeTestContainer())
    }

    private func movie(tmdb: Int, duration: Int? = 6000) -> Movie {
        let movie = Movie(id: "m\(tmdb)", streamId: tmdb, name: "Movie \(tmdb)")
        movie.tmdbId = tmdb
        movie.durationSecs = duration
        return movie
    }

    private func pausedMovie(_ tmdb: Int, progress: Double = 25, at date: String? = nil) -> TraktPlaybackItem {
        TraktPlaybackItem(
            progress: progress, pausedAt: date ?? paused,
            movie: TraktWatchedMedia(ids: TraktIDs(tmdb: tmdb, trakt: nil)), show: nil, episode: nil
        )
    }

    private func pausedEpisode(show: Int, season: Int, number: Int, progress: Double = 50) -> TraktPlaybackItem {
        TraktPlaybackItem(
            progress: progress, pausedAt: paused, movie: nil,
            show: TraktWatchedMedia(ids: TraktIDs(tmdb: show, trakt: nil)),
            episode: .init(season: season, number: number)
        )
    }

    @Test func `a paused movie takes its position and date`() throws {
        let context = try makeContext()
        let local = movie(tmdb: 1)
        context.insert(local)

        #expect(TraktPlaybackImporter.apply([pausedMovie(1, progress: 25)], in: context) == 1)
        #expect(local.watchProgress == 1500)
        #expect(local.lastWatchedDate == pausedDate)
        #expect(!local.isWatched)
    }

    @Test func `newer local playback wins`() throws {
        let context = try makeContext()
        let local = movie(tmdb: 1)
        local.watchProgress = 4000
        local.lastWatchedDate = pausedDate.addingTimeInterval(3600)
        context.insert(local)

        #expect(TraktPlaybackImporter.apply([pausedMovie(1)], in: context) == 0)
        #expect(local.watchProgress == 4000)
    }

    /// Finished here: it stays in Recently Watched rather than reopening.
    @Test func `a movie finished here is left alone`() throws {
        let context = try makeContext()
        let local = movie(tmdb: 1)
        local.isWatched = true
        context.insert(local)

        #expect(TraktPlaybackImporter.apply([pausedMovie(1)], in: context) == 0)
        #expect(local.lastWatchedDate == nil)
    }

    @Test func `a paused episode positions the episode and moves its series up`() throws {
        let context = try makeContext()
        let series = Series(id: "s1", seriesId: 1, name: "Show")
        series.tmdbId = 9
        context.insert(series)
        let episode = Episode(id: "e1", episodeId: "1", title: "E", containerExtension: "mkv", seasonNum: 2, episodeNum: 3)
        episode.durationSecs = 3000
        episode.series = series
        context.insert(episode)

        #expect(TraktPlaybackImporter.apply([pausedEpisode(show: 9, season: 2, number: 3)], in: context) == 1)
        #expect(episode.watchProgress == 1500)
        #expect(episode.lastWatchedDate == pausedDate)
        #expect(series.lastWatchedDate == pausedDate)
    }

    /// Episodes not fetched yet: the date still moves the series up the rail.
    @Test func `a series without episodes still takes the date`() throws {
        let context = try makeContext()
        let series = Series(id: "s1", seriesId: 1, name: "Show")
        series.tmdbId = 9
        context.insert(series)

        #expect(TraktPlaybackImporter.apply([pausedEpisode(show: 9, season: 1, number: 1)], in: context) == 1)
        #expect(series.lastWatchedDate == pausedDate)
    }

    @Test func `the newest pause of a movie wins`() throws {
        let context = try makeContext()
        let local = movie(tmdb: 1)
        context.insert(local)
        let older = pausedMovie(1, progress: 10, at: "2026-09-01T00:00:00.000Z")
        let newer = pausedMovie(1, progress: 50)

        _ = TraktPlaybackImporter.apply([older, newer], in: context)
        #expect(local.watchProgress == 3000)
    }

    @Test func `a percent becomes seconds`() {
        #expect(TraktPlaybackImporter.position(33.3, of: 3000) == 999)
        #expect(TraktPlaybackImporter.position(140, of: 3000) == 3000)
    }

    /// Re-watched elsewhere: an already-watched movie moves up Recently
    /// Watched, without counting as newly marked.
    @Test func `a re-watched movie takes the newer date`() throws {
        let context = try makeContext()
        let local = movie(tmdb: 1)
        local.isWatched = true
        local.lastWatchedDate = Date(timeIntervalSince1970: 0)
        context.insert(local)
        let watched = TraktWatchedMovie(movie: TraktWatchedMedia(ids: TraktIDs(tmdb: 1, trakt: nil)), lastWatchedAt: paused)

        let summary = TraktWatchedImporter.apply(movies: [watched], shows: [], in: context)
        #expect(summary.moviesMarked == 0)
        #expect(local.lastWatchedDate == pausedDate)
    }

    // MARK: - Episodes not fetched yet

    private func unfetchedSeries(in context: ModelContext) -> Series {
        let series = Series(id: "s1", seriesId: 1, name: "Show")
        series.tmdbId = 9
        context.insert(series)
        return series
    }

    private func parsedEpisode(season: Int, number: Int) -> ParsedEpisode {
        ParsedEpisode(
            id: "s\(season)-\(number)", episodeId: "\(season)\(number)", title: "E\(number)",
            containerExtension: "mkv", seasonNum: season, episodeNum: number,
            added: nil, directSource: nil, durationSecs: 1200,
            movieImage: nil, rating: nil, airDate: nil, plot: nil
        )
    }

    private func episode(_ series: Series, season: Int, number: Int) -> Episode? {
        series.episodes.first { $0.seasonNum == season && $0.episodeNum == number }
    }

    @Test func `a pause waits for its episode and lands when the episodes arrive`() throws {
        let context = try makeContext()
        let series = unfetchedSeries(in: context)
        _ = TraktPlaybackImporter.apply([pausedEpisode(show: 9, season: 7, number: 12, progress: 40)], in: context)
        #expect(TraktPendingWatchedStore.load()[9]?.paused?["7x12"] != nil)

        // What the Continue Watching fetch or the detail screen does.
        series.insertEpisodes([parsedEpisode(season: 7, number: 11), parsedEpisode(season: 7, number: 12)], into: context)

        #expect(episode(series, season: 7, number: 12)?.watchProgress == 480)
        #expect(episode(series, season: 7, number: 12)?.lastWatchedDate == pausedDate)
        #expect(episode(series, season: 7, number: 11)?.watchProgress == 0)
        #expect(TraktPendingWatchedStore.load()[9] == nil)
    }

    /// Finished since it was paused: the watched import parked the same episode,
    /// and applies first.
    @Test func `parked watched state wins over a parked pause`() throws {
        let context = try makeContext()
        let series = unfetchedSeries(in: context)
        let watched = TraktWatchedShow(
            show: TraktWatchedMedia(ids: TraktIDs(tmdb: 9, trakt: nil)),
            seasons: [TraktWatchedSeason(
                number: 1, episodes: [TraktWatchedEpisode(number: 2, lastWatchedAt: "2026-09-21T20:00:00.000Z")]
            )]
        )
        _ = TraktWatchedImporter.apply(movies: [], shows: [watched], in: context)
        _ = TraktPlaybackImporter.apply([pausedEpisode(show: 9, season: 1, number: 2)], in: context)

        series.insertEpisodes([parsedEpisode(season: 1, number: 2)], into: context)

        #expect(episode(series, season: 1, number: 2)?.isWatched == true)
        #expect(episode(series, season: 1, number: 2)?.watchProgress == 1200)
    }

    /// A re-import re-parks the watched half of a show; its pauses survive.
    @Test func `the watched import keeps parked pauses`() throws {
        let context = try makeContext()
        _ = unfetchedSeries(in: context)
        _ = TraktPlaybackImporter.apply([pausedEpisode(show: 9, season: 3, number: 1)], in: context)
        let watched = TraktWatchedShow(
            show: TraktWatchedMedia(ids: TraktIDs(tmdb: 9, trakt: nil)),
            seasons: [TraktWatchedSeason(number: 1, episodes: [TraktWatchedEpisode(number: 1, lastWatchedAt: paused)])]
        )

        _ = TraktWatchedImporter.apply(movies: [], shows: [watched], in: context)

        #expect(TraktPendingWatchedStore.load()[9]?.paused?["3x1"] != nil)
        #expect(TraktPendingWatchedStore.load()[9]?.episodes["1x1"] != nil)
    }

    /// The provider may be a season behind Trakt: the pause keeps waiting through
    /// a fetch that doesn't list its episode, then expires.
    @Test func `a pause for an episode the provider lacks waits, then expires`() throws {
        let context = try makeContext()
        let series = unfetchedSeries(in: context)
        let parkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        _ = TraktPlaybackImporter.apply([pausedEpisode(show: 9, season: 8, number: 1)], in: context, now: parkedAt)
        series.insertEpisodes([parsedEpisode(season: 7, number: 1)], into: context)

        TraktWatchedImporter.applyPending(to: series, now: parkedAt.addingTimeInterval(29 * 86400))
        #expect(TraktPendingWatchedStore.load()[9]?.paused?["8x1"] != nil)

        TraktWatchedImporter.applyPending(to: series, now: parkedAt.addingTimeInterval(31 * 86400))
        #expect(TraktPendingWatchedStore.load()[9] == nil)
    }

    /// Written before pauses were parked: no `paused` key.
    @Test func `a pending file without pauses still decodes`() throws {
        let json = Data(#"{"shows":{"9":{"episodes":{"1x2":1413046854}}}}"#.utf8)
        let decoded = try JSONDecoder().decode(TraktPendingWatched.self, from: json)
        #expect(decoded[9]?.episodes["1x2"] == 1_413_046_854)
        #expect(decoded[9]?.paused == nil)
    }
}

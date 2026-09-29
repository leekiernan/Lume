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
@Suite(.serialized, .globalState)
struct TraktPlaybackImporterTests {
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
}

//
//  ContinueWatchingTests.swift
//  LumeTests
//
//  Which episode a series continues with, when a series is finished (out of
//  Continue Watching, into Recently Watched), and a movie's time left.
//

import Foundation
@testable import Lume
import Testing

struct ContinueWatchingTests {
    private func mark(_ season: Int, _ episode: Int, progress: Double = 0, watched: Bool = false) -> EpisodeMark {
        EpisodeMark(season: season, episode: episode, progress: progress, duration: 2400, isWatched: watched)
    }

    @Test func `an episode in progress is where a series continues`() {
        let continuation = ContinueWatching.continuation(from: [
            mark(1, 1, watched: true), mark(1, 2, progress: 600), mark(1, 3)
        ])
        #expect(continuation == SeriesContinuation(season: 1, episode: 2, fraction: 0.25, remaining: 1800))
    }

    /// Across a season boundary, and unstarted: an empty bar.
    @Test func `otherwise it continues after the furthest watched`() {
        let continuation = ContinueWatching.continuation(from: [
            mark(1, 1, watched: true), mark(1, 2, watched: true), mark(2, 1)
        ])
        // Unstarted: all of it is left.
        #expect(continuation == SeriesContinuation(season: 2, episode: 1, fraction: 0, remaining: 2400))
    }

    /// The series page's Resume button wraps to the premiere here; the rail
    /// has nothing left to continue — the series is finished.
    @Test func `the last episode watched finishes the series`() {
        #expect(ContinueWatching.continuation(from: [mark(1, 1, watched: true), mark(1, 2, watched: true)]) == nil)
        // A skipped episode doesn't hold it back once the finale is watched.
        #expect(ContinueWatching.continuation(from: [mark(1, 1), mark(1, 2, watched: true)]) == nil)
    }

    /// A new season arriving after the finale makes it unfinished again.
    @Test func `a new season brings a finished series back`() {
        let continuation = ContinueWatching.continuation(from: [
            mark(1, 1, watched: true), mark(1, 2, watched: true), mark(2, 1)
        ])
        #expect(continuation?.season == 2)
    }

    @Test func `nothing watched yet starts at the first episode`() {
        #expect(ContinueWatching.continuation(from: [mark(2, 1), mark(1, 3), mark(1, 1)])
            == SeriesContinuation(season: 1, episode: 1, fraction: 0, remaining: 2400))
        #expect(ContinueWatching.continuation(from: []) == nil)
    }

    @Test func `a movie's time left`() {
        #expect(ContinueWatching.remaining(progress: 1200, duration: 3600) == 2400)
        #expect(ContinueWatching.remaining(progress: 4000, duration: 3600) == 0)
        #expect(ContinueWatching.remaining(progress: 100, duration: nil) == nil)
        #expect(ContinueWatching.fraction(progress: 900, duration: 3600) == 0.25)
    }

    @Test func `the labels`() {
        #expect(ContinueWatching.episodeLabel(SeriesContinuation(season: 7, episode: 12, fraction: nil)).contains("12"))
        // Never "0m left": under a minute still reads a minute.
        #expect(ContinueWatching.remainingLabel(20).contains("1"))
        #expect(ContinueWatching.remainingLabel(3900).contains("5"))
    }

    /// A series card always reads the episode and, when known, its time left.
    @Test func `the series label pairs the episode with its time left`() {
        let known = SeriesContinuation(season: 7, episode: 12, fraction: 0.5, remaining: 1800)
        #expect(ContinueWatching.seriesLabel(known)
            == ContinueWatching.episodeLabel(known) + " · " + ContinueWatching.remainingLabel(1800))
        let unknown = SeriesContinuation(season: 7, episode: 12, fraction: nil)
        #expect(ContinueWatching.seriesLabel(unknown) == ContinueWatching.episodeLabel(unknown))
    }

    @MainActor
    @Test func `title tiles keep a stable colour per title`() {
        #expect(PosterTitleTile.paletteIndex(for: "Sintel") == PosterTitleTile.paletteIndex(for: "Sintel"))
        let indices = Set(["Sintel", "Big Buck Bunny", "Tears of Steel", "Spring", "Charge", "Wing It!"]
            .map(PosterTitleTile.paletteIndex(for:)))
        #expect(indices.count > 1)
        #expect(indices.allSatisfy { (0 ..< PosterTitleTile.palette.count).contains($0) })
    }

    @Test func `resume bars exclude watched and unstarted content without changing the continuation threshold`() {
        #expect(ContinueWatching.resumeFraction(progress: 0, duration: 100, isWatched: false) == nil)
        #expect(ContinueWatching.resumeFraction(progress: -5, duration: 100, isWatched: false) == nil)
        #expect(ContinueWatching.resumeFraction(progress: .nan, duration: 100, isWatched: false) == nil)
        #expect(ContinueWatching.resumeFraction(progress: 30, duration: 100, isWatched: true) == nil)
        #expect(ContinueWatching.resumeFraction(progress: 0.5, duration: 100, isWatched: false) == 0.005)
    }

    @Test func `resume bars require a duration and clamp overrun without marking content watched`() {
        for duration in [nil, 0, -1] as [Int?] {
            #expect(ContinueWatching.resumeFraction(progress: 25, duration: duration, isWatched: false) == nil)
        }
        #expect(ContinueWatching.resumeFraction(progress: 25, duration: 100, isWatched: false) == 0.25)
        #expect(ContinueWatching.resumeFraction(progress: 125, duration: 100, isWatched: false) == 1)
    }

    @Test @MainActor func `home cards use the shared resume gate but keep series lookup and live content separate`() {
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        movie.durationSecs = 100
        movie.watchProgress = 25
        let item = HomeMediaItem.movie(movie)
        #expect(item.progress(seriesResume: [:]) == 0.25)
        movie.isWatched = true
        #expect(item.progress(seriesResume: [:]) == nil)
        movie.isWatched = false
        movie.durationSecs = nil
        #expect(item.progress(seriesResume: [:]) == nil)
        let series = Series(id: "show", seriesId: 1, name: "Show")
        #expect(HomeMediaItem.series(series).progress(seriesResume: [series.id: 0.4]) == 0.4)
        #expect(HomeMediaItem.series(series).progress(seriesResume: [:]) == nil)
        let channel = LiveStream(id: "live", streamId: 1, name: "Live")
        #expect(HomeMediaItem.live(channel).progress(seriesResume: [channel.id: 0.4]) == nil)
    }
}

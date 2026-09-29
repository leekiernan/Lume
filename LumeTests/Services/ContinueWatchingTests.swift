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
        #expect(continuation == SeriesContinuation(season: 1, episode: 2, fraction: 0.25))
    }

    /// Across a season boundary, and unstarted: an empty bar.
    @Test func `otherwise it continues after the furthest watched`() {
        let continuation = ContinueWatching.continuation(from: [
            mark(1, 1, watched: true), mark(1, 2, watched: true), mark(2, 1)
        ])
        #expect(continuation == SeriesContinuation(season: 2, episode: 1, fraction: 0))
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
            == SeriesContinuation(season: 1, episode: 1, fraction: 0))
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
}

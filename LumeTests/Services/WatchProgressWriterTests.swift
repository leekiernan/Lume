//
//  WatchProgressWriterTests.swift
//  LumeTests
//
//  What a progress save does to a title's watched state: crossing the line
//  marks it watched once, and a rewatch puts it back in progress.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct WatchProgressWriterTests {
    private func movie(in container: ModelContainer, watched: Bool) throws -> Movie {
        let movie = Movie(id: UUID().uuidString, streamId: 1, name: "Film")
        movie.durationSecs = 6000
        movie.isWatched = watched
        movie.watchProgress = watched ? 6000 : 0
        container.mainContext.insert(movie)
        try container.mainContext.save()
        return movie
    }

    private func stored(_ id: String, in container: ModelContainer) throws -> Movie {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Movie>()).first { $0.id == id })
    }

    @Test func `crossing the line marks a title watched, once`() async throws {
        let container = try makeTestContainer()
        let movie = try movie(in: container, watched: false)
        let writer = WatchProgressWriter(container: container)

        let first = await writer.record(ref: .movie(movie.id), progress: 5500, duration: 6000)
        let second = await writer.record(ref: .movie(movie.id), progress: 5800, duration: 6000)

        #expect(first != nil)
        #expect(second == nil)
        #expect(try stored(movie.id, in: container).isWatched)
    }

    @Test func `a rewatch past the first minute is in progress again`() async throws {
        let container = try makeTestContainer()
        let movie = try movie(in: container, watched: true)

        let change = await WatchProgressWriter(container: container).record(ref: .movie(movie.id), progress: 900, duration: 6000)

        // Reported, so the player can show it on the screens' model too.
        #expect(change?.isWatched == false)
        let saved = try stored(movie.id, in: container)
        #expect(!saved.isWatched)
        #expect(saved.watchProgress == 900)
    }

    @Test func `opening a watched title and backing out keeps it watched`() async throws {
        let container = try makeTestContainer()
        let movie = try movie(in: container, watched: true)

        let change = await WatchProgressWriter(container: container).record(ref: .movie(movie.id), progress: 20, duration: 6000)

        #expect(change == nil)
        #expect(try stored(movie.id, in: container).isWatched)
        #expect(try stored(movie.id, in: container).watchProgress == 6000)
    }

    @Test func `an early pause in a long replay cannot erase the completed watch`() async throws {
        let container = try makeTestContainer()
        let movie = try movie(in: container, watched: true)
        let change = await WatchProgressWriter(container: container).record(ref: .movie(movie.id), progress: 90, duration: 12000)
        #expect(change == nil)
        #expect(try stored(movie.id, in: container).isWatched)
        #expect(try stored(movie.id, in: container).watchProgress == 6000)
    }

    /// Finished again: watched, and reported as a completion — a second play.
    @Test func `finishing a rewatch completes it again`() async throws {
        let container = try makeTestContainer()
        let movie = try movie(in: container, watched: true)
        let writer = WatchProgressWriter(container: container)

        await writer.record(ref: .movie(movie.id), progress: 900, duration: 6000)
        let completion = await writer.record(ref: .movie(movie.id), progress: 5700, duration: 6000)

        #expect(completion?.isWatched == true)
        #expect(try stored(movie.id, in: container).isWatched)
    }
}

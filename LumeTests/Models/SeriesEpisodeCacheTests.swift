//
//  SeriesEpisodeCacheTests.swift
//  LumeTests
//
//  Covers the episode cache behind the series detail screens. Xtream and
//  Stalker episodes are fetched lazily per series and are never swept by
//  playlist sync, so a cached season used to stick forever — a device that had
//  opened a show before the provider added an episode kept showing the short
//  list no matter how often the playlist synced. Sync is now what reopens the
//  question: a bumped `lastModified`, or a playlist that synced past the fetch.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SeriesEpisodeCacheTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Series.self, Episode.self])
        // `cloudKitDatabase: .none`: the catalog uses `@Attribute(.unique)`,
        // which CloudKit forbids and fails the load on a signed test host.
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func parsed(season: Int, number: Int, duration: Int? = nil, image: String? = nil,
                        rating: Double? = nil, airDate: String? = nil, plot: String? = nil) -> ParsedEpisode
    {
        ParsedEpisode(
            id: "s\(season)e\(number)",
            episodeId: "\(season)-\(number)",
            title: "S\(season)E\(number)",
            containerExtension: "mkv",
            seasonNum: season,
            episodeNum: number,
            added: nil,
            directSource: nil,
            durationSecs: duration,
            movieImage: image,
            rating: rating,
            airDate: airDate,
            plot: plot
        )
    }

    @Test func `a series that never fetched episodes is stale`() {
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        #expect(series.episodesAreStale(lastSyncedAt: nil))
    }

    @Test func `a fresh fetch is not stale`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show", lastModified: "1700000000")
        context.insert(series)

        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        #expect(series.episodesFetchedAt != nil)
        // A sync that ran before the fetch settles nothing new.
        #expect(!series.episodesAreStale(lastSyncedAt: Date().addingTimeInterval(-60)))
    }

    @Test func `a bumped provider lastModified invalidates the cache`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show", lastModified: "1700000000")
        context.insert(series)
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        // What a sync does when the provider adds an episode.
        series.lastModified = "1700009999"

        #expect(series.episodesAreStale(lastSyncedAt: nil))
    }

    @Test func `a sync since the fetch invalidates the cache`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Portals that don't maintain `last_modified` leave it nil forever, so
        // the playlist's own sync date is the only signal left.
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        #expect(series.episodesAreStale(lastSyncedAt: Date().addingTimeInterval(60)))
    }

    @Test func `a never-synced playlist leaves a fetched list alone`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        #expect(!series.episodesAreStale(lastSyncedAt: nil))
    }

    @Test func `a refresh merges in the newly added episode`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([1, 2, 3, 4].map { parsed(season: 1, number: $0) }, into: context)

        // The refresh re-fetches the whole season, now five episodes long.
        series.insertEpisodes([1, 2, 3, 4, 5].map { parsed(season: 1, number: $0) }, into: context)

        #expect(series.episodes.count == 5)
        #expect(series.episodes.count(where: { $0.episodeNum == 5 }) == 1)
    }

    @Test func `a short provider response never drops cached episodes`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([1, 2, 3, 4, 5].map { parsed(season: 1, number: $0) }, into: context)

        // A hiccuping portal answering with a truncated season must not take
        // watched episodes with it — the merge is additive on purpose.
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        #expect(series.episodes.count == 5)
    }

    @Test func `refresh updates metadata on the same episode without changing user state`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([parsed(season: 1, number: 1, duration: 100, image: "old.jpg", rating: 5, airDate: "2020-01-01", plot: "Old")], into: context)
        let episode = try #require(series.episodes.first)
        episode.watchProgress = 42
        episode.isWatched = true
        let watchedAt = Date(timeIntervalSince1970: 1234)
        episode.lastWatchedDate = watchedAt
        episode.localFileURL = "file:///download.mkv"
        episode.downloadStatus = .completed
        series.insertEpisodes([parsed(season: 1, number: 1, duration: 200, image: "new.jpg", rating: 8, airDate: "2026-01-01", plot: "New")], into: context)

        #expect(series.episodes.count == 1)
        #expect(series.episodes.first === episode)
        #expect(episode.durationSecs == 200 && episode.rating == 8)
        #expect(episode.movieImage == "new.jpg" && episode.airDate == "2026-01-01" && episode.plot == "New")
        #expect(episode.watchProgress == 42 && episode.isWatched && episode.lastWatchedDate == watchedAt)
        #expect(episode.localFileURL == "file:///download.mkv" && episode.downloadStatus == .completed)
    }

    @Test func `partial or empty metadata never erases good values`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([parsed(season: 1, number: 1, duration: 100, image: "old.jpg", rating: 5, airDate: "2020-01-01", plot: "Old")], into: context)
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)
        series.insertEpisodes([parsed(season: 1, number: 1, duration: 0, image: "", rating: 0, airDate: "  ", plot: "\n")], into: context)
        series.insertEpisodes([parsed(season: 1, number: 1, duration: -1, rating: .nan)], into: context)
        let episode = try #require(series.episodes.first)

        #expect(episode.durationSecs == 100 && episode.rating == 5)
        #expect(episode.movieImage == "old.jpg" && episode.airDate == "2020-01-01" && episode.plot == "Old")
    }

    @Test func `duplicate episodes update supplied metadata without inserting twice`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        context.insert(series)
        series.insertEpisodes([parsed(season: 1, number: 1, plot: "First"), parsed(season: 1, number: 1, plot: "Last")], into: context)

        #expect(series.episodes.count == 1)
        #expect(series.episodes.first?.plot == "Last")
    }

    @Test func `identical metadata does not dirty an episode`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let episode = Episode(id: "e1", episodeId: "1", title: "Episode", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
        let metadata = parsed(season: 1, number: 1, duration: 100, image: "still.jpg", rating: 5, airDate: "2020-01-01", plot: "Plot")
        context.insert(episode)
        episode.applyProviderMetadata(metadata)
        try context.save()
        episode.applyProviderMetadata(metadata)

        #expect(!context.hasChanges)
    }

    /// Cloud watched state waits as pending until its episode exists; adding
    /// episodes must prompt a sync pass so it applies while the page is open.
    @Test func `adding episodes announces them, and only new ones`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let series = Series(id: "p-series-2", seriesId: 2, name: "Show", lastModified: "1700000000")
        context.insert(series)
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .lumeEpisodesDidMaterialize, object: series, queue: nil
        ) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)
        series.insertEpisodes([parsed(season: 1, number: 1)], into: context)

        #expect(announcements == 1)
    }
}

//
//  ContentSyncAreaGatingTests.swift
//  LumeTests
//
//  The Settings › Library toggle across every sync source: which areas a run
//  syncs, what it reports as covered, how the m3u/WebDAV skip-if-unchanged
//  digest is scoped to them, and that an m3u import with an area switched off
//  neither writes nor sweeps that area's rows.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct ContentSyncAreaGatingTests {
    private let allContent: Set<AppArea> = [.movies, .series, .liveTV]

    // MARK: - Run areas and coverage

    @Test func `a regular run syncs the enabled areas and a repair only the enabled ones it asks for`() {
        #expect(ContentSyncManager.syncAreas(enabled: [.movies, .series], repairing: nil) == [.movies, .series])
        #expect(ContentSyncManager.syncAreas(enabled: [.movies, .series], repairing: [.series, .liveTV]) == [.series])
    }

    @Test func `sources without live channels report Live TV as unsupported`() {
        for source in [PlaylistSourceType.webdav, .jellyfin, .emby, .plex] {
            #expect(ContentSyncManager.unsupportedAreas(for: source) == [.liveTV])
        }
        for source in [PlaylistSourceType.xtream, .m3u, .stalker] {
            #expect(ContentSyncManager.unsupportedAreas(for: source).isEmpty)
        }
    }

    // MARK: - Digest scoping

    @Test func `the digest is unchanged when every area the source supplies was synced`() {
        #expect(ContentSyncManager.areaScopedDigest("abc", areas: allContent, sourceType: .m3u) == "abc")
        // A share has no Live TV, so its absence changes nothing.
        #expect(ContentSyncManager.areaScopedDigest("abc", areas: [.movies, .series], sourceType: .webdav) == "abc")
    }

    @Test func `a run with an area switched off stores a digest the full run never matches`() {
        let moviesOnly = ContentSyncManager.areaScopedDigest("abc", areas: [.movies], sourceType: .m3u)
        let noLive = ContentSyncManager.areaScopedDigest("abc", areas: [.movies, .series], sourceType: .m3u)
        #expect(moviesOnly != "abc")
        #expect(noLive != "abc")
        #expect(moviesOnly != noLive)
        #expect(ContentSyncManager.areaScopedDigest("abc", areas: [.series], sourceType: .webdav) != "abc")
    }

    // MARK: - m3u import

    @Test func `a restricted batch drops only the switched-off areas`() {
        let batch = M3UBatchClassifier.classify(Self.entries(tag: "a"))
        #expect(!batch.live.isEmpty && !batch.movies.isEmpty && !batch.episodes.isEmpty)

        let moviesOnly = batch.restricted(to: [.movies])
        #expect(moviesOnly.live.isEmpty)
        #expect(moviesOnly.episodes.isEmpty)
        #expect(moviesOnly.movies.map(\.url) == batch.movies.map(\.url))

        let everything = batch.restricted(to: allContent)
        #expect(everything.live.count == batch.live.count)
        #expect(everything.episodes.count == batch.episodes.count)
    }

    @Test func `an import with Live TV and Series off leaves their rows untouched`() async throws {
        let container = try makeTestContainer()
        let playlist = Playlist(name: "Areas", m3uURL: "file:///areas.m3u", epgURL: nil)
        do {
            let context = ModelContext(container)
            context.insert(playlist)
            try context.save()
        }
        let playlistId = playlist.id
        let manager = ContentSyncManager(modelContainer: container)

        // A full first import: one channel, one movie, one episode.
        try await manager.importFixture(Self.entries(tag: "a"), playlistId: playlistId, areas: allContent)

        // The next run has only Movies on. Its file dropped the old channel and
        // episode and added new ones; none of that may reach the store.
        try await manager.importFixture(Self.entries(tag: "b"), playlistId: playlistId, areas: [.movies])

        let context = ModelContext(container)
        let channels = try context.fetch(FetchDescriptor<LiveStream>()).map(\.name)
        #expect(channels == ["Channel a"])
        let episodes = try context.fetch(FetchDescriptor<Episode>())
        #expect(episodes.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 1)
        let movies = try Set(context.fetch(FetchDescriptor<Movie>()).map(\.name))
        #expect(movies.contains("Movie b"))
        let liveCategories = try context.fetch(FetchDescriptor<Lume.Category>()).filter { $0.type == .live }
        #expect(liveCategories.map(\.name) == ["News a"])
    }

    /// One channel, one movie and one episode, named after `tag` so two
    /// fixtures share no row.
    private static func entries(tag: String) -> [M3UEntry] {
        [
            M3UEntry(
                name: "Channel \(tag)", url: "http://example.com/live/\(tag).ts",
                tvgId: nil, logo: nil, group: "News \(tag)", type: nil
            ),
            M3UEntry(
                name: "Movie \(tag)", url: "http://example.com/movie/\(tag).mp4",
                tvgId: nil, logo: nil, group: "Films", type: nil
            ),
            M3UEntry(
                name: "Show \(tag) S01E01 Pilot", url: "http://example.com/series/\(tag).mkv",
                tvgId: nil, logo: nil, group: "Shows \(tag)", type: nil
            )
        ]
    }
}

private extension ContentSyncManager {
    /// The import-then-sweep half of `importM3UFile`, on an in-memory batch.
    func importFixture(_ entries: [M3UEntry], playlistId: UUID, areas: Set<AppArea>) throws {
        let state = M3UImportState(areas: areas)
        seedImportState(state, playlistId: playlistId)
        try importBatch(M3UBatchClassifier.classify(entries), playlistId: playlistId, state: state)
        pruneStaleM3URows(playlistId: playlistId, state: state)
    }
}

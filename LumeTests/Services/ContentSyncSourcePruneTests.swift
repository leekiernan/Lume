//
//  ContentSyncSourcePruneTests.swift
//  LumeTests
//
//  The prefix-scoped sweeps the Jellyfin/Emby and Plex pipelines prune
//  through. They take the same paged sweep and coverage gate as Xtream and
//  m3u, but on the source's own id range (`"<playlist>-plex-"`), so a sweep
//  never reads — let alone deletes — a row another source wrote under the same
//  playlist.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct ContentSyncSourcePruneTests {
    /// Mirrors the sweep's page size; fixtures span more than one page.
    private let pageSize = 2000

    private func insertMovies(ids: [String], container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for (index, id) in ids.enumerated() {
            context.insert(Movie(id: id, streamId: index, name: "Movie \(index)"))
        }
        try context.save()
    }

    private func storedMovieIds(_ container: ModelContainer) throws -> Set<String> {
        try Set(ModelContext(container).fetch(FetchDescriptor<Movie>()).map(\.id))
    }

    @Test func `a media-server sweep deletes only unseen rows under its own prefix`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let prefix = ContentSyncManager.plexIdPrefix(playlistId)
        let owned = (0 ..< (pageSize + 100)).map { "\(prefix)\($0)" }
        let foreign = (0 ..< 50).map { "\(playlistId.uuidString)-movie-\($0)" }
        try insertMovies(ids: owned + foreign, container: container)

        let seen = Set(owned.enumerated().filter { $0.offset % 4 != 0 }.map(\.element))
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneMovies(playlistId: playlistId, idPrefix: prefix, seenIds: seen)

        #expect(try storedMovieIds(container) == seen.union(foreign))
    }

    @Test func `a media-server sweep that covers too little of the library is held back`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let prefix = ContentSyncManager.mediaServerIdPrefix(playlistId, flavor: .jellyfin)
        let owned = (0 ..< pageSize).map { "\(prefix)\($0)" }
        try insertMovies(ids: owned, container: container)

        // One page of a library answered before the connection dropped: the
        // walk returns short, and sweeping on it would delete the rest.
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneMovies(playlistId: playlistId, idPrefix: prefix, seenIds: Set(owned.prefix(100)))

        #expect(try storedMovieIds(container).count == pageSize)
    }

    @Test func `media-server episodes are swept on their own id range`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let prefix = ContentSyncManager.plexIdPrefix(playlistId)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let keptShow = Series(id: "\(prefix)show-kept", seriesId: 1, name: "Kept")
        let droppedShow = Series(id: "\(prefix)show-dropped", seriesId: 2, name: "Dropped")
        context.insert(keptShow)
        context.insert(droppedShow)
        for index in 0 ..< 10 {
            for show in [keptShow, droppedShow] {
                let episode = Episode(
                    id: "\(prefix)episode-\(show.seriesId)-\(index)", episodeId: "\(index)", title: "E\(index)",
                    containerExtension: "mkv", seasonNum: 1, episodeNum: index
                )
                context.insert(episode)
                episode.series = show
            }
        }
        try context.save()

        let keptEpisodes = Set((0 ..< 9).map { "\(prefix)episode-1-\($0)" })
        let manager = ContentSyncManager(modelContainer: container)
        await manager.pruneSeries(playlistId: playlistId, idPrefix: prefix, seenIds: [keptShow.id])
        await manager.pruneEpisodes(playlistId: playlistId, idPrefix: prefix, seenIds: keptEpisodes)

        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Series>()).map(\.id) == ["\(prefix)show-kept"])
        // The dropped show's episodes cascaded; the kept show lost only the one
        // episode the server stopped listing.
        #expect(try Set(check.fetch(FetchDescriptor<Episode>()).map(\.id)) == keptEpisodes)
    }
}

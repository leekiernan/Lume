import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct PlaylistSyncCoverageTests {
    @Test func `area skipped by latest sync requires another sync when enabled`() throws {
        let suiteName = "PlaylistSyncCoverageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let playlistID = UUID()

        PlaylistSyncCoverage.record([.movies, .series], playlistID: playlistID, defaults: defaults)

        #expect(PlaylistSyncCoverage.missingEnabledAreas(
            playlistID: playlistID,
            disabledAreasRaw: "liveTV",
            defaults: defaults
        ).isEmpty)
        #expect(PlaylistSyncCoverage.missingEnabledAreas(
            playlistID: playlistID,
            disabledAreasRaw: "",
            defaults: defaults
        ) == [.liveTV])
    }

    @Test func `new successful coverage replaces rather than unions with old run`() throws {
        let suiteName = "PlaylistSyncCoverageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let playlistID = UUID()

        PlaylistSyncCoverage.record([.movies, .series, .liveTV], playlistID: playlistID, defaults: defaults)
        PlaylistSyncCoverage.record([.movies, .series], playlistID: playlistID, defaults: defaults)

        #expect(PlaylistSyncCoverage.areas(playlistID: playlistID, defaults: defaults) == [.movies, .series])
    }

    @Test func `repair coverage merges with the phases from the prior full sync`() throws {
        let suiteName = "PlaylistSyncCoverageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let playlistID = UUID()

        PlaylistSyncCoverage.record([.movies, .series], playlistID: playlistID, defaults: defaults)
        PlaylistSyncCoverage.recordMerging([.liveTV], playlistID: playlistID, defaults: defaults)

        #expect(PlaylistSyncCoverage.areas(playlistID: playlistID, defaults: defaults) == [.movies, .series, .liveTV])
    }

    @Test func `upgrade bootstrap recognises catalog kinds already on disk`() throws {
        let suiteName = "PlaylistSyncCoverageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Existing", serverURL: "https://example.test", username: "u", password: "p")
        let prefix = playlist.id.uuidString
        context.insert(playlist)
        context.insert(Movie(id: "\(prefix)-movie-1", streamId: 1, name: "Movie", categoryId: "vod"))
        context.insert(LiveStream(id: "\(prefix)-live-1", streamId: 1, name: "Channel", categoryId: "live"))
        try context.save()

        PlaylistSyncCoverage.bootstrapFromCatalogIfNeeded(
            playlistID: playlist.id,
            context: context,
            defaults: defaults
        )

        #expect(PlaylistSyncCoverage.areas(playlistID: playlist.id, defaults: defaults) == [.movies, .liveTV])
        #expect(PlaylistSyncCoverage.missingEnabledAreas(
            playlistID: playlist.id,
            disabledAreasRaw: "",
            defaults: defaults
        ) == [.series])
    }
}

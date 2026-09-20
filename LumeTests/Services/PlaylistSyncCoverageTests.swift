import Foundation
@testable import Lume
import Testing

struct PlaylistSyncCoverageTests {
    @Test func `area skipped by latest sync requires another sync when enabled`() throws {
        let suiteName = "PlaylistSyncCoverageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let playlistID = UUID()

        PlaylistSyncCoverage.record([.movies, .series], playlistID: playlistID, defaults: defaults)

        #expect(!PlaylistSyncCoverage.isMissingEnabledArea(
            playlistID: playlistID,
            disabledAreasRaw: "liveTV",
            defaults: defaults
        ))
        #expect(PlaylistSyncCoverage.isMissingEnabledArea(
            playlistID: playlistID,
            disabledAreasRaw: "",
            defaults: defaults
        ))
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
}

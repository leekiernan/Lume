import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct PlaylistSyncCoverageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `stamping coverage preserves unknown areas and other playlists`() throws {
        try withDefaults { defaults in
            let playlistID = UUID()
            let other = UUID()
            let key = PlaylistSyncCoverage.key(playlistID: playlistID)
            defaults.set(["futureArea": 123.0, "liveTV": 456.0], forKey: key)
            PlaylistSyncCoverage.record([.series], playlistID: other, at: now, defaults: defaults)
            PlaylistSyncCoverage.record([.movies], playlistID: playlistID, at: now, defaults: defaults)

            let raw = try #require(defaults.dictionary(forKey: key) as? [String: Double])
            #expect(raw == ["futureArea": 123, "liveTV": 456, "movies": now.timeIntervalSince1970])
            #expect(PlaylistSyncCoverage.refreshDates(playlistID: playlistID, defaults: defaults) == [
                .liveTV: Date(timeIntervalSince1970: 456), .movies: now
            ])
            #expect(PlaylistSyncCoverage.refreshDates(playlistID: other, defaults: defaults) == [.series: now])
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "PlaylistSyncCoverageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func repairs(
        _ playlistID: UUID,
        disabled: String = "",
        frequency: SyncFrequency = .daily,
        at date: Date? = nil,
        _ defaults: UserDefaults
    ) -> Set<AppArea> {
        PlaylistSyncCoverage.missingAreasForAutomaticRepair(
            playlistID: playlistID,
            disabledAreasRaw: disabled,
            frequency: frequency,
            now: date ?? now,
            defaults: defaults
        )
    }

    @Test func `an area no sync has fetched is missing once enabled`() throws {
        try withDefaults { defaults in
            let playlistID = UUID()
            PlaylistSyncCoverage.record([.movies, .series], playlistID: playlistID, at: now, defaults: defaults)

            #expect(repairs(playlistID, disabled: "liveTV", defaults).isEmpty)
            #expect(repairs(playlistID, defaults) == [.liveTV])
        }
    }

    @Test func `a sync under another profile keeps the areas it skipped`() throws {
        try withDefaults { defaults in
            let playlistID = UUID()
            // A Live TV profile refreshes; later a Movies and Series one does.
            PlaylistSyncCoverage.record([.liveTV], playlistID: playlistID, at: now, defaults: defaults)
            let later = now.addingTimeInterval(3600)
            PlaylistSyncCoverage.record([.movies, .series], playlistID: playlistID, at: later, defaults: defaults)

            let dates = PlaylistSyncCoverage.refreshDates(playlistID: playlistID, defaults: defaults)
            #expect(dates == [.liveTV: now, .movies: later, .series: later])
        }
    }

    @Test func `switching back soon after an area's refresh asks for nothing`() throws {
        try withDefaults { defaults in
            let playlistID = UUID()
            PlaylistSyncCoverage.record([.liveTV], playlistID: playlistID, at: now, defaults: defaults)
            PlaylistSyncCoverage.record(
                [.movies, .series], playlistID: playlistID, at: now.addingTimeInterval(3600), defaults: defaults
            )

            let liveOnly = "home,movies,series"
            #expect(repairs(playlistID, disabled: liveOnly, at: now.addingTimeInterval(2 * 3600), defaults).isEmpty)
        }
    }

    @Test func `an area older than the sync frequency is owed a refresh`() throws {
        try withDefaults { defaults in
            let playlistID = UUID()
            PlaylistSyncCoverage.record([.liveTV], playlistID: playlistID, at: now, defaults: defaults)

            let nextDay = now.addingTimeInterval(25 * 3600)
            #expect(repairs(playlistID, disabled: "home,movies,series", at: nextDay, defaults) == [.liveTV])
            #expect(repairs(playlistID, disabled: "home,movies,series", frequency: .weekly, at: nextDay, defaults).isEmpty)
        }
    }

    @Test func `manual skipped area does not trigger automatic repair`() throws {
        try withDefaults { defaults in
            let playlistID = UUID()
            PlaylistSyncCoverage.record([.movies, .series], playlistID: playlistID, at: now, defaults: defaults)
            PlaylistSyncCoverage.deferAutomaticRepair([.liveTV], playlistID: playlistID, defaults: defaults)

            #expect(repairs(playlistID, defaults).isEmpty)
        }
    }

    @Test func `first profile switch still repairs an area that was never manually skipped`() throws {
        try withDefaults { defaults in
            let playlistID = UUID()
            // First launch synced Movies and Series under the default profile. No
            // manual refresh has opted out of Live TV yet.
            PlaylistSyncCoverage.record([.movies, .series], playlistID: playlistID, at: now, defaults: defaults)

            #expect(repairs(playlistID, defaults) == [.liveTV])
        }
    }

    @Test func `refreshing an area clears its manual deferral`() throws {
        try withDefaults { defaults in
            let playlistID = UUID()
            PlaylistSyncCoverage.deferAutomaticRepair([.liveTV], playlistID: playlistID, defaults: defaults)
            PlaylistSyncCoverage.record([.liveTV], playlistID: playlistID, at: now, defaults: defaults)

            #expect(PlaylistSyncCoverage.deferredAreas(playlistID: playlistID, defaults: defaults).isEmpty)
        }
    }

    @Test func `upgrade from area coverage dates those areas from the last sync`() throws {
        try withDefaults { defaults in
            let container = try makeTestContainer()
            let context = ModelContext(container)
            let playlistID = UUID()
            defaults.set(["liveTV", "movies"], forKey: PlaylistSyncCoverage.legacyKey(playlistID: playlistID))

            PlaylistSyncCoverage.bootstrapFromCatalogIfNeeded(
                playlistID: playlistID, lastSyncDate: now, context: context, defaults: defaults
            )

            #expect(PlaylistSyncCoverage.refreshDates(playlistID: playlistID, defaults: defaults) == [.liveTV: now, .movies: now])
            #expect(defaults.object(forKey: PlaylistSyncCoverage.legacyKey(playlistID: playlistID)) == nil)
        }
    }

    @Test func `upgrade bootstrap recognises catalog kinds already on disk`() throws {
        try withDefaults { defaults in
            let container = try makeTestContainer()
            let context = ModelContext(container)
            let playlist = Playlist(name: "Existing", serverURL: "https://example.test", username: "u", password: "p")
            let prefix = playlist.id.uuidString
            context.insert(playlist)
            context.insert(Movie(id: "\(prefix)-movie-1", streamId: 1, name: "Movie", categoryId: "vod"))
            context.insert(LiveStream(id: "\(prefix)-live-1", streamId: 1, name: "Channel", categoryId: "live"))
            try context.save()

            PlaylistSyncCoverage.bootstrapFromCatalogIfNeeded(
                playlistID: playlist.id, lastSyncDate: now, context: context, defaults: defaults
            )

            #expect(PlaylistSyncCoverage.areas(playlistID: playlist.id, defaults: defaults) == [.movies, .liveTV])
            #expect(repairs(playlist.id, defaults) == [.series])
            #expect(PlaylistSyncCoverage.areasWithRows(playlistID: playlist.id, context: context) == [.movies, .liveTV])
        }
    }

    @Test func `a bootstrap with no successful sync leaves its areas owed one`() throws {
        try withDefaults { defaults in
            let container = try makeTestContainer()
            let context = ModelContext(container)
            let playlistID = UUID()
            defaults.set(["liveTV"], forKey: PlaylistSyncCoverage.legacyKey(playlistID: playlistID))

            PlaylistSyncCoverage.bootstrapFromCatalogIfNeeded(
                playlistID: playlistID, lastSyncDate: nil, context: context, defaults: defaults
            )

            #expect(repairs(playlistID, disabled: "home,movies,series", defaults) == [.liveTV])
        }
    }
}

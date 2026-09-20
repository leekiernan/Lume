//
//  PlaylistSyncCoverage.swift
//  Lume
//
//  Device-local record of which app areas participated in a playlist's most
//  recent successful catalog sync. Area visibility is profile-scoped, while the
//  catalog and Playlist.lastSyncDate are device-wide. Without this second piece
//  of state, a sync run under a profile that hides Live TV can stamp the whole
//  playlist as current even though it deliberately fetched no channels.
//

import Foundation
import SwiftData

nonisolated enum PlaylistSyncCoverage {
    static func key(playlistID: UUID) -> String {
        "sync.areaCoverage.\(playlistID.uuidString)"
    }

    static func areas(playlistID: UUID, defaults: UserDefaults = .standard) -> Set<AppArea> {
        let rawValues = defaults.stringArray(forKey: key(playlistID: playlistID)) ?? []
        return Set(rawValues.compactMap(AppArea.init(rawValue:)))
    }

    /// Replaces, rather than unions, the previous coverage. If Live TV was
    /// skipped by the latest successful run, enabling it must override the
    /// playlist's fresh `lastSyncDate` and schedule another run.
    static func record(
        _ areas: Set<AppArea>,
        playlistID: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(areas.map(\.rawValue).sorted(), forKey: key(playlistID: playlistID))
    }

    static func recordMerging(
        _ areas: Set<AppArea>,
        playlistID: UUID,
        defaults: UserDefaults = .standard
    ) {
        record(self.areas(playlistID: playlistID, defaults: defaults).union(areas), playlistID: playlistID, defaults: defaults)
    }

    static func remove(playlistID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(playlistID: playlistID))
    }

    /// Whether an enabled content area was omitted from the playlist's latest
    /// successful sync. Home has no catalog phase of its own.
    static func missingEnabledAreas(
        playlistID: UUID,
        disabledAreasRaw: String,
        defaults: UserDefaults = .standard
    ) -> Set<AppArea> {
        let required = AppAreaSettings.enabledContentAreas(disabledRaw: disabledAreasRaw)
        return required.subtracting(areas(playlistID: playlistID, defaults: defaults))
    }

    /// Seeds installs upgrading from before coverage bookkeeping existed. Any
    /// catalog kind that already has a row must have completed an earlier
    /// provider import, so it should not be downloaded again merely to create
    /// the marker. A genuinely skipped area has no rows and remains missing.
    @MainActor
    static func bootstrapFromCatalogIfNeeded(
        playlistID: UUID,
        context: ModelContext,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.object(forKey: key(playlistID: playlistID)) == nil else { return }

        let prefix = playlistID.uuidString
        var existing: Set<AppArea> = []
        var movie = FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) })
        movie.fetchLimit = 1
        if let rows = try? context.fetch(movie), !rows.isEmpty { existing.insert(.movies) }

        var series = FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) })
        series.fetchLimit = 1
        if let rows = try? context.fetch(series), !rows.isEmpty { existing.insert(.series) }

        var live = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) })
        live.fetchLimit = 1
        if let rows = try? context.fetch(live), !rows.isEmpty { existing.insert(.liveTV) }

        record(existing, playlistID: playlistID, defaults: defaults)
    }
}

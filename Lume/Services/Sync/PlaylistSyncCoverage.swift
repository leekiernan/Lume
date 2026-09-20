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

    static func remove(playlistID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(playlistID: playlistID))
    }

    /// Whether an enabled content area was omitted from the playlist's latest
    /// successful sync. Home has no catalog phase of its own.
    static func isMissingEnabledArea(
        playlistID: UUID,
        disabledAreasRaw: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let required = AppAreaSettings.enabledContentAreas(disabledRaw: disabledAreasRaw)
        return !required.isSubset(of: areas(playlistID: playlistID, defaults: defaults))
    }
}

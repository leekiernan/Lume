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
    /// Area → when a successful sync last refreshed it, as a unix timestamp.
    static func key(playlistID: UUID) -> String {
        "sync.areaRefreshed.\(playlistID.uuidString)"
    }

    /// The set of areas the latest successful sync covered — the format
    /// before per-area dates. Read once to seed `key`, then removed.
    static func legacyKey(playlistID: UUID) -> String {
        "sync.areaCoverage.\(playlistID.uuidString)"
    }

    /// Areas a viewer explicitly chose not to refresh in the manual flow. They
    /// remain genuinely absent from coverage, but must not be silently turned
    /// into a blocking profile-switch repair later.
    static func deferredKey(playlistID: UUID) -> String {
        "sync.areaCoverage.deferred.\(playlistID.uuidString)"
    }

    /// When each area was last refreshed. An area missing here has never
    /// been fetched on this device.
    static func refreshDates(playlistID: UUID, defaults: UserDefaults = .standard) -> [AppArea: Date] {
        let raw = defaults.dictionary(forKey: key(playlistID: playlistID)) as? [String: Double] ?? [:]
        var dates: [AppArea: Date] = [:]
        for (area, timestamp) in raw {
            guard let area = AppArea(rawValue: area) else { continue }
            dates[area] = Date(timeIntervalSince1970: timestamp)
        }
        return dates
    }

    static func areas(playlistID: UUID, defaults: UserDefaults = .standard) -> Set<AppArea> {
        Set(refreshDates(playlistID: playlistID, defaults: defaults).keys)
    }

    static func deferredAreas(playlistID: UUID, defaults: UserDefaults = .standard) -> Set<AppArea> {
        let rawValues = defaults.stringArray(forKey: deferredKey(playlistID: playlistID)) ?? []
        return Set(rawValues.compactMap(AppArea.init(rawValue:)))
    }

    /// Stamps the areas a successful sync refreshed, leaving every other
    /// area's date alone. Profiles share the catalog but not their areas: a
    /// sync under a Movies-only profile says nothing about how fresh Live TV
    /// is, so it must not erase the date another profile's sync left there.
    static func record(
        _ areas: Set<AppArea>,
        playlistID: UUID,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var raw = defaults.dictionary(forKey: key(playlistID: playlistID)) as? [String: Double] ?? [:]
        for area in areas {
            raw[area.rawValue] = date.timeIntervalSince1970
        }
        defaults.set(raw, forKey: key(playlistID: playlistID))
        clearDeferred(areas, playlistID: playlistID, defaults: defaults)
    }

    /// Records visible "Skipped for this profile" work from a successful
    /// manual refresh. The next profile may still offer that work through the
    /// manual Sync action, but automatic repair leaves the user's choice alone.
    static func deferAutomaticRepair(
        _ areas: Set<AppArea>,
        playlistID: UUID,
        defaults: UserDefaults = .standard
    ) {
        guard !areas.isEmpty else { return }
        let deferred = deferredAreas(playlistID: playlistID, defaults: defaults).union(areas)
        defaults.set(deferred.map(\.rawValue).sorted(), forKey: deferredKey(playlistID: playlistID))
    }

    static func remove(playlistID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(playlistID: playlistID))
        defaults.removeObject(forKey: legacyKey(playlistID: playlistID))
        defaults.removeObject(forKey: deferredKey(playlistID: playlistID))
    }

    /// Enabled areas owed a refresh by their own date: never fetched, or last
    /// fetched longer ago than `frequency`. Home has no catalog phase of its own. The playlist's `lastSyncDate` is
    /// device-wide and moves with any profile's sync, so it can't speak for
    /// an area that sync skipped.
    static func staleEnabledAreas(
        playlistID: UUID,
        disabledAreasRaw: String,
        frequency: SyncFrequency,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Set<AppArea> {
        let dates = refreshDates(playlistID: playlistID, defaults: defaults)
        return AppAreaSettings.enabledContentAreas(disabledRaw: disabledAreasRaw).filter {
            frequency.isDue(lastSyncDate: dates[$0], now: now)
        }
    }

    /// Stale areas still eligible for automatic repair. A manual sync can
    /// deliberately skip an area for the active profile; preserve that choice
    /// until the viewer explicitly syncs under a profile that uses it.
    static func missingAreasForAutomaticRepair(
        playlistID: UUID,
        disabledAreasRaw: String,
        frequency: SyncFrequency,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Set<AppArea> {
        staleEnabledAreas(
            playlistID: playlistID,
            disabledAreasRaw: disabledAreasRaw,
            frequency: frequency,
            now: now,
            defaults: defaults
        )
        .subtracting(deferredAreas(playlistID: playlistID, defaults: defaults))
    }

    private static func clearDeferred(
        _ refreshedAreas: Set<AppArea>,
        playlistID: UUID,
        defaults: UserDefaults
    ) {
        let remaining = deferredAreas(playlistID: playlistID, defaults: defaults).subtracting(refreshedAreas)
        if remaining.isEmpty {
            defaults.removeObject(forKey: deferredKey(playlistID: playlistID))
        } else {
            defaults.set(remaining.map(\.rawValue).sorted(), forKey: deferredKey(playlistID: playlistID))
        }
    }

    /// Seeds the dates on first use. An install from before per-area dates
    /// carries the set of areas its latest sync covered; one from before any
    /// bookkeeping has only its catalog, where a kind that already has rows
    /// must have completed an earlier provider import. Either way those areas
    /// date from the playlist's last sync — the best this device knows — and
    /// a genuinely skipped area has no date and remains missing.
    @MainActor
    static func bootstrapFromCatalogIfNeeded(
        playlistID: UUID,
        lastSyncDate: Date?,
        context: ModelContext,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.object(forKey: key(playlistID: playlistID)) == nil else { return }

        let existing: Set<AppArea> = if let legacy = defaults.stringArray(forKey: legacyKey(playlistID: playlistID)) {
            Set(legacy.compactMap(AppArea.init(rawValue:)))
        } else {
            areasWithRows(playlistID: playlistID, context: context)
        }
        // Without a successful sync to date them, they're owed one.
        let date = lastSyncDate ?? .distantPast
        var raw: [String: Double] = [:]
        for area in existing {
            raw[area.rawValue] = date.timeIntervalSince1970
        }
        defaults.set(raw, forKey: key(playlistID: playlistID))
        defaults.removeObject(forKey: legacyKey(playlistID: playlistID))
    }

    /// The content areas with at least one row in the catalog for this
    /// playlist: what the viewer can already browse while a refresh runs.
    @MainActor
    static func areasWithRows(playlistID: UUID, context: ModelContext) -> Set<AppArea> {
        let prefix = playlistID.uuidString
        var existing: Set<AppArea> = []
        var movie = FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) })
        movie.fetchLimit = 1
        if let count = try? context.fetchCount(movie), count > 0 { existing.insert(.movies) }

        var series = FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) })
        series.fetchLimit = 1
        if let count = try? context.fetchCount(series), count > 0 { existing.insert(.series) }

        var live = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) })
        live.fetchLimit = 1
        if let count = try? context.fetchCount(live), count > 0 { existing.insert(.liveTV) }
        return existing
    }
}

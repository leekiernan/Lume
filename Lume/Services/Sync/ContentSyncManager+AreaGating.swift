//
//  ContentSyncManager+AreaGating.swift
//  Lume
//
//  The per-type content phases of a playlist sync, and the switch that skips
//  them. An area the user has turned off in Settings › Library is not synced at
//  all — that is what "stop processing updates" means there. Rows already in
//  the store are left alone, so switching the area back on shows them at once
//  and the next sync brings them up to date.
//
//  Every source honours it: `syncAreas` fixes the set once per run, Xtream
//  gates its category and content phases on it, Stalker and the media servers
//  skip the phases of a switched-off area, and the m3u/WebDAV import drops
//  that area's entries before the upsert and holds back its sweeps (see
//  `M3UClassifiedBatch.restricted(to:)`). What the run reports as covered —
//  see `PlaylistSyncCoverage` — is the areas it synced plus those the source
//  cannot supply at all, so re-enabling an area schedules the sync that
//  fetches it.
//
//  Kept out of `ContentSyncManager` itself so the gate is one self-contained
//  place rather than conditionals threaded through every pipeline.
//

import Foundation

extension ContentSyncManager {
    /// The content areas one sync run imports: those switched on for the active
    /// profile when the run starts, narrowed to the areas a repair asks for.
    nonisolated static func syncAreas(enabled: Set<AppArea>, repairing: Set<AppArea>?) -> Set<AppArea> {
        repairing.map { enabled.intersection($0) } ?? enabled
    }

    /// Content areas `sourceType` has no catalog for. Recorded as covered on
    /// every successful run: the source can never supply them, so their
    /// absence must not read as a skipped phase that needs a repair sync.
    nonisolated static func unsupportedAreas(for sourceType: PlaylistSourceType) -> Set<AppArea> {
        sourceType.canCarryLiveChannels ? [] : [.liveTV]
    }

    /// A skip-if-unchanged digest scoped to the areas the import ran for. The
    /// m3u and WebDAV digests stand for "this file was imported in full"; an
    /// import with an area switched off did not import it, so switching the
    /// area back on must miss the stored digest even when the file is
    /// unchanged. Unscoped when every area the source can supply was synced,
    /// so the common all-enabled case keeps the digests stored before scoping.
    nonisolated static func areaScopedDigest(
        _ digest: String,
        areas: Set<AppArea>,
        sourceType: PlaylistSourceType
    ) -> String {
        let supplied = AppAreaSettings.enabledContentAreas(disabledRaw: "").subtracting(unsupportedAreas(for: sourceType))
        let synced = areas.intersection(supplied)
        guard synced != supplied else { return digest }
        return digest + "|areas:" + synced.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Xtream can fetch each catalog kind independently. `areas` is the run's
    /// `syncAreas`: the enabled areas, or only the missing ones for a repair.
    func performXtreamSync(
        playlist: Playlist,
        playlistId: UUID,
        progress: SyncProgress?,
        areas: Set<AppArea>
    ) async throws -> Set<AppArea> {
        await progress?.start(.authenticating)
        let authResponse = try await xtreamRequest { try await $0.getInfo(playlist: playlist) }
        updatePlaylistInfo(playlistId, with: authResponse)
        await progress?.complete(.authenticating)

        try await syncCategories(for: playlist, playlistId: playlistId, progress: progress, areas: areas)
        return try await syncEnabledContent(for: playlist, playlistId: playlistId, progress: progress, areas: areas)
    }

    private func syncCategories(
        for playlist: Playlist,
        playlistId: UUID,
        progress: SyncProgress?,
        areas: Set<AppArea>
    ) async throws {
        func includes(_ area: AppArea) -> Bool {
            areas.contains(area)
        }

        if includes(.movies) {
            await progress?.start(.movieCategories)
            try await syncVODCategories(for: playlist, playlistId: playlistId, progress: progress)
            await progress?.complete(.movieCategories)
        }
        if includes(.series) {
            await progress?.start(.seriesCategories)
            try await syncSeriesCategories(for: playlist, playlistId: playlistId, progress: progress)
            await progress?.complete(.seriesCategories)
        }
        if includes(.liveTV) {
            await progress?.start(.liveCategories)
            try await syncLiveCategories(for: playlist, playlistId: playlistId, progress: progress)
            await progress?.complete(.liveCategories)
        }
    }

    /// Runs the movie, series and live phases for the areas that are switched
    /// on. Serialized and spaced apart on purpose — see
    /// `spaceContentPhaseRequests` for the connection-cap reason. The spacing
    /// only happens *between* phases that actually run, so switching an area
    /// off removes its delay along with its requests.
    func syncEnabledContent(
        for playlist: Playlist,
        playlistId: UUID,
        progress: SyncProgress? = nil,
        areas: Set<AppArea>? = nil
    ) async throws -> Set<AppArea> {
        var ranAPhase = false
        var syncedAreas: Set<AppArea> = []
        func includes(_ area: AppArea) -> Bool {
            AppAreaSettings.isEnabled(area) && (areas?.contains(area) ?? true)
        }

        if includes(.movies) {
            try await syncMovies(for: playlist, playlistId: playlistId, progress: progress)
            ranAPhase = true
            syncedAreas.insert(.movies)
        }

        if includes(.series) {
            if ranAPhase { try await spaceContentPhaseRequests() }
            try await syncSeries(for: playlist, playlistId: playlistId, progress: progress)
            ranAPhase = true
            syncedAreas.insert(.series)
        }

        if includes(.liveTV) {
            if ranAPhase { try await spaceContentPhaseRequests() }
            try await syncLiveStreams(for: playlist, playlistId: playlistId, progress: progress)
            syncedAreas.insert(.liveTV)
        }

        return syncedAreas
    }
}

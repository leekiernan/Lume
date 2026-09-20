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
//  Kept out of `ContentSyncManager` itself so the gate is one self-contained
//  place rather than three conditionals threaded through the orchestration.
//

import Foundation

extension ContentSyncManager {
    /// Xtream can fetch each catalog kind independently. A repair passes only
    /// the missing areas; a regular sync passes nil and retains the profile's
    /// normal area gating.
    func performXtreamSync(
        playlist: Playlist,
        playlistId: UUID,
        progress: SyncProgress?,
        areas: Set<AppArea>?
    ) async throws -> Set<AppArea> {
        await progress?.start(.authenticating)
        let authResponse = try await xtreamClient.getInfo(playlist: playlist)
        updatePlaylistInfo(playlistId, with: authResponse)
        await progress?.complete(.authenticating)

        try await syncCategories(for: playlist, playlistId: playlistId, progress: progress, areas: areas)
        return try await syncEnabledContent(for: playlist, playlistId: playlistId, progress: progress, areas: areas)
    }

    private func syncCategories(
        for playlist: Playlist,
        playlistId: UUID,
        progress: SyncProgress?,
        areas: Set<AppArea>?
    ) async throws {
        func includes(_ area: AppArea) -> Bool {
            areas?.contains(area) ?? true
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

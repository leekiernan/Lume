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
    /// Runs the movie, series and live phases for the areas that are switched
    /// on. Serialized and spaced apart on purpose — see
    /// `spaceContentPhaseRequests` for the connection-cap reason. The spacing
    /// only happens *between* phases that actually run, so switching an area
    /// off removes its delay along with its requests.
    func syncEnabledContent(
        for playlist: Playlist,
        playlistId: UUID,
        progress: SyncProgress? = nil
    ) async throws {
        var ranAPhase = false

        if AppAreaSettings.isEnabled(.movies) {
            try await syncMovies(for: playlist, playlistId: playlistId, progress: progress)
            ranAPhase = true
        }

        if AppAreaSettings.isEnabled(.series) {
            if ranAPhase { try await spaceContentPhaseRequests() }
            try await syncSeries(for: playlist, playlistId: playlistId, progress: progress)
            ranAPhase = true
        }

        if AppAreaSettings.isEnabled(.liveTV) {
            if ranAPhase { try await spaceContentPhaseRequests() }
            try await syncLiveStreams(for: playlist, playlistId: playlistId, progress: progress)
        }
    }
}

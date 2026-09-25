//
//  MainTabView+AutoSync.swift
//  Lume
//
//  Automatic sync: which playlists are due (or missing a content area the
//  profile enables), the queue of blocking progress covers, and what drives
//  re-evaluation. Kept out of MainTabView, which composes the tabs.
//

import SwiftUI

extension MainTabView {
    var syncFrequency: SyncFrequency {
        SyncFrequency.resolve(syncFrequencyRaw)
    }

    /// Re-evaluate auto-sync when the profile or its enabled areas change, even
    /// though neither operation changes the shared playlist rows themselves.
    var autoSyncTrigger: AutoSyncTrigger {
        AutoSyncTrigger(
            playlistCount: playlists.count,
            activeProfileToken: activeProfileToken,
            disabledAreasRaw: disabledAreasRaw
        )
    }

    /// The playlist the content tabs are showing, resolved rather than read raw:
    /// the stored id can name a deleted playlist, in which case the app falls
    /// back to the same playlist every other surface does, and auto-sync has to
    /// follow it there.
    var activePlaylistID: String {
        playlists.activeID(for: selectedPlaylistID)
    }

    // MARK: - Automatic sync

    /// Enqueues every due playlist for a blocking, progress-visible sync and
    /// presents the first one — the playlist on screen, plus any the viewer
    /// just added (see `AutoSync.shouldSync`). Covers the never-synced first
    /// launch (where `lastSyncDate == nil` makes a playlist due) as well as
    /// periodic refreshes.
    func enqueueDueSyncs(_ candidates: [Playlist]) {
        guard !isUITesting else { return }

        for playlist in candidates where !isQueued(playlist) {
            guard let request = syncRequest(for: playlist) else { continue }
            autoSyncAttempted.insert(playlist.id)
            syncQueue.append(request)
        }
        promoteNextIfIdle()
    }

    func isQueued(_ playlist: Playlist) -> Bool {
        activeSyncRequest?.id == playlist.id || syncQueue.contains { $0.id == playlist.id }
    }

    func syncRequest(for playlist: Playlist) -> PlaylistSyncRequest? {
        PlaylistSyncCoverage.bootstrapFromCatalogIfNeeded(
            playlistID: playlist.id,
            context: modelContext
        )
        let missingAreas = PlaylistSyncCoverage.missingEnabledAreas(
            playlistID: playlist.id,
            disabledAreasRaw: disabledAreasRaw
        )
        let candidate = playlist.autoSyncCandidate(activeID: activePlaylistID)
        let isRegularlyDue = AutoSync.shouldSync(
            candidate,
            frequency: syncFrequency,
            alreadyStarted: autoSyncAttempted.contains(playlist.id)
        )
        // A repair also opens the blocking sync cover, so it follows the same
        // rule as a regular sync: only the playlist on screen (or one just
        // added) earns it; any other syncs when the viewer switches to it.
        let needsCoverage = !missingAreas.isEmpty && playlist.syncEnabled && playlist.syncStatus != .syncing
            && (candidate.isActive || candidate.wasAddedThisSession)
        guard isRegularlyDue || needsCoverage else { return nil }

        // A due playlist gets its ordinary refresh. Only the otherwise-current
        // Xtream playlist uses the narrow repair path; m3u and Stalker do not
        // expose independent per-area bulk imports.
        let repairingAreas = !isRegularlyDue && playlist.sourceType == .xtream ? missingAreas : nil
        return PlaylistSyncRequest(playlist: playlist, repairingAreas: repairingAreas)
    }

    /// Whether the auto-sync queue holds anything, including the playlist in
    /// the cover. Reported to `EPGSyncService` so the guide refresh reads the
    /// queue itself instead of predicting it.
    var isAutoSyncBusy: Bool {
        activeSyncRequest != nil || !syncQueue.isEmpty
    }

    /// Presents the next queued playlist's sync cover when none is showing. The
    /// `SyncProgressView` auto-starts the sync and dismisses itself on success;
    /// the cover's `onDismiss` calls back here to advance the queue.
    func promoteNextIfIdle() {
        guard activeSyncRequest == nil, !syncQueue.isEmpty else { return }
        activeSyncRequest = syncQueue.removeFirst()
    }
}

struct PlaylistSyncRequest: Identifiable {
    let playlist: Playlist
    let repairingAreas: Set<AppArea>?

    var id: UUID {
        playlist.id
    }
}

struct AutoSyncTrigger: Hashable {
    let playlistCount: Int
    let activeProfileToken: String
    let disabledAreasRaw: String
}

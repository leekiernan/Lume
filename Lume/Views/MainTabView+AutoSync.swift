//
//  MainTabView+AutoSync.swift
//  Lume
//
//  Automatic sync: which playlists are due (or missing a content area the
//  profile enables), the queue of blocking progress covers, and what drives
//  re-evaluation. Kept out of MainTabView, which composes the tabs.
//

import OSLog
import SwiftData
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
            repairLedger.record(request.repairedAreas, for: playlist.id)
            if request.runsInBackground {
                startBackgroundSync(request)
            } else {
                syncQueue.append(request)
            }
        }
        promoteNextIfIdle()
    }

    /// Refreshes areas the viewer can already browse without covering them:
    /// the rows on screen stay usable and update in place as the sync lands.
    /// Failure is the sync's own to report (`Playlist.syncStatus`); the area
    /// is retried next session (`AutoSync.RepairLedger`).
    func startBackgroundSync(_ request: PlaylistSyncRequest) {
        let playlist = request.playlist
        let plan = PlaylistSyncPlan(sourceType: playlist.sourceType, repairingAreas: request.repairingAreas)
        let container = modelContext.container
        backgroundSyncIDs.insert(playlist.id)
        Logger.database.info(
            "Refreshing \(plan.syncAreas.map(\.rawValue).sorted(), privacy: .public) in the background for playlist \(playlist.id)"
        )
        Task {
            defer { backgroundSyncIDs.remove(playlist.id) }
            try? await PlaylistSyncRun.perform(playlist, container: container, plan: plan)
        }
    }

    /// iCloud brought new connection details for these playlists. Any whose
    /// sync this session failed against the old ones gets another automatic
    /// attempt; one still on screen in the failed cover retries itself (see
    /// `SyncProgressView`), so it's already queued and skipped here.
    func retryFailedSyncs(_ ids: Set<UUID>) {
        let plan = AutoSync.ReconnectionPlan(
            playlists: playlists, reconnectedIDs: ids,
            queuedIDs: Set(syncQueue.map(\.id)).union(backgroundSyncIDs).union(activeSyncRequest.map { [$0.id] } ?? [])
        )
        plan.resetAttempts(&autoSyncAttempted, ledger: &repairLedger)
        enqueueDueSyncs(playlists.filter { plan.enqueueIDs.contains($0.id) })
    }

    func isQueued(_ playlist: Playlist) -> Bool {
        activeSyncRequest?.id == playlist.id
            || syncQueue.contains { $0.id == playlist.id }
            || backgroundSyncIDs.contains(playlist.id)
    }

    func syncRequest(for playlist: Playlist) -> PlaylistSyncRequest? {
        PlaylistSyncCoverage.bootstrapFromCatalogIfNeeded(
            playlistID: playlist.id,
            lastSyncDate: playlist.lastSyncDate,
            context: modelContext
        )
        let staleAreas = PlaylistSyncCoverage.missingAreasForAutomaticRepair(
            playlistID: playlist.id,
            disabledAreasRaw: disabledAreasRaw,
            frequency: syncFrequency
        )
        // Only the playlist on screen (or one just added) earns automatic
        // work; any other syncs when the viewer switches to it.
        let input = AutoSync.PlanInput(
            candidate: playlist.autoSyncCandidate(activeID: activePlaylistID),
            playlistID: playlist.id,
            frequency: syncFrequency,
            alreadyStarted: autoSyncAttempted.contains(playlist.id),
            staleAreas: staleAreas,
            supportsAreaRepair: playlist.sourceType == .xtream
        )
        guard let plan = AutoSync.plan(
            input,
            ledger: repairLedger,
            areasWithRows: { PlaylistSyncCoverage.areasWithRows(playlistID: playlist.id, context: modelContext) }
        ) else { return nil }
        return PlaylistSyncRequest(
            playlist: playlist,
            repairingAreas: plan.repairingAreas,
            repairedAreas: plan.repairedAreas,
            runsInBackground: plan.runsInBackground
        )
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
    /// The areas this run repairs, for `AutoSync.RepairLedger`.
    var repairedAreas: Set<AppArea> = []
    /// A repair of areas the catalog already has rows for, run without the
    /// blocking cover.
    var runsInBackground = false

    var id: UUID {
        playlist.id
    }
}

struct AutoSyncTrigger: Hashable {
    let playlistCount: Int
    let activeProfileToken: String
    let disabledAreasRaw: String
}

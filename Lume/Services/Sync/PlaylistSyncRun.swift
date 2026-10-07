//
//  PlaylistSyncRun.swift
//  Lume
//
//  One playlist sync together with the work every run owes around it: the
//  guide refresh told it's sharing the provider's connections, a background
//  assertion so a trip to the Home screen doesn't kill it, and the search
//  index kicked once new titles land. The progress screen and the silent
//  background repair both run through here, so neither can skip a step.
//

import Foundation
import SwiftData

@MainActor
enum PlaylistSyncRun {
    static func perform(
        _ playlist: Playlist,
        container: ModelContainer,
        plan: PlaylistSyncPlan,
        progress: SyncProgress? = nil,
        notifications: InAppNotifications? = nil
    ) async throws {
        let notifications = notifications ?? .shared
        let profileToken = ActiveProfileStore.current?.uuidString ?? ""
        let subject = InAppNotifications.Subject.playlist(playlist.id, name: playlist.name)
        // Reported to the guide refresh so the two never share the provider's
        // connection allowance: it stands aside (or is cut short) while this
        // runs, and catches up once nothing else is pending — see
        // `EPGRefreshGate`. Every start is paired with exactly one finish.
        let epgSync = EPGSyncService.shared
        epgSync.contentSyncDidStart()
        var succeeded = false
        defer { epgSync.contentSyncDidFinish(succeeded: succeeded, refreshedLiveTV: succeeded && plan.refreshesGuide) }

        let syncManager = ContentSyncManager(modelContainer: container)
        do {
            try await BackgroundActivity.perform("Playlist sync") {
                try await syncManager.syncPlaylist(
                    playlist,
                    progress: progress,
                    full: plan.full,
                    repairingAreas: plan.repairingAreas,
                    syncAreas: plan.syncAreas
                )
            }
            try Task.checkCancellation()
        } catch {
            notifications.report(
                Task.isCancelled || error is CancellationError ? .cancelled : .failed,
                subject: subject, startedUnder: profileToken, currentProfileToken: ActiveProfileStore.current?.uuidString ?? ""
            )
            throw error
        }
        succeeded = true
        notifications.report(
            .succeeded, subject: subject, startedUnder: profileToken, currentProfileToken: ActiveProfileStore.current?.uuidString ?? ""
        )
        // Newly synced titles need indexing; the launch-time pass may already
        // be finished, so kick a fresh one — but hold it off a few seconds so
        // loading the embedding model and the per-chunk saves don't fight the
        // first browse of the catalog the user just synced.
        ContentIndexingService.shared.kick(after: .seconds(3))
    }
}

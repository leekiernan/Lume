//
//  SyncGuideStatus.swift
//  Lume
//
//  The TV guide's line on the sync screen. A sync that brings in Live TV
//  owes a guide refresh, which `EPGSyncService` runs in the background once
//  the sync is done (`EPGRefreshGate` keeps the two off the provider's
//  connection at the same time). The screen never waits for it: this only
//  says where it is, so the viewer can leave whenever they like.
//

import Foundation

nonisolated enum SyncGuideStatus: Equatable {
    /// Queued behind the sync, or the sync hasn't finished yet.
    case afterSync
    case updating
    case updated
    /// The sync didn't finish, or the refresh itself failed.
    case notUpdated

    /// - Parameters:
    ///   - syncFinished: the playlist sync completed.
    ///   - syncFailed: the playlist sync failed — no refresh is owed then.
    ///   - guideRunning: a guide refresh is running now.
    ///   - sawGuideRunning: one ran at some point after the sync finished.
    ///   - guideUpdatedSinceSync: a refresh succeeded after the sync finished.
    static func status(
        syncFinished: Bool,
        syncFailed: Bool,
        guideRunning: Bool,
        sawGuideRunning: Bool,
        guideUpdatedSinceSync: Bool
    ) -> Self {
        if syncFailed { return .notUpdated }
        guard syncFinished else { return .afterSync }
        if guideRunning { return .updating }
        if guideUpdatedSinceSync { return .updated }
        return sawGuideRunning ? .notUpdated : .afterSync
    }
}

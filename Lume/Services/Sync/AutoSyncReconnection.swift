import Foundation

extension AutoSync {
    /// Reset every affected failure, but never enqueue a second owner for work
    /// already covered by a progress cover, pending request or background run.
    struct ReconnectionPlan: Equatable {
        let resetIDs: Set<UUID>
        let enqueueIDs: Set<UUID>

        init(playlists: [Playlist], reconnectedIDs: Set<UUID>, queuedIDs: Set<UUID>) {
            self.init(reconnectedIDs: reconnectedIDs,
                      failedIDs: Set(playlists.filter { $0.syncStatus == .error }.map(\.id)), queuedIDs: queuedIDs)
        }

        init(reconnectedIDs: Set<UUID>, failedIDs: Set<UUID>, queuedIDs: Set<UUID>) {
            resetIDs = reconnectedIDs.intersection(failedIDs)
            enqueueIDs = resetIDs.subtracting(queuedIDs)
        }

        func resetAttempts(_ attempts: inout Set<UUID>, ledger: inout RepairLedger) {
            attempts.subtract(resetIDs)
            for id in resetIDs {
                ledger.reset(id)
            }
        }
    }
}

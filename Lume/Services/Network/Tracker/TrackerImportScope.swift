//
//  TrackerImportScope.swift
//  Lume
//
//  Whose history a tracker import may write. An import fetches the account's
//  history over the network and then applies it to the catalog; in between,
//  the viewer can disconnect, sign in to another account, switch profile, or
//  change something locally that is still on its way out. Any of those means
//  the fetched history no longer describes what it would overwrite.
//

import Foundation

struct TrackerImportScope: Equatable {
    let account: String?
    let profileID: UUID?

    /// Taken once the outbox has been flushed: local changes go up before the
    /// history comes down, so the import can't undo them. `nil` while some are
    /// still pending (offline, or the flush failed); the import waits for the
    /// next one.
    @MainActor
    static func begin(after queue: TrackerMutationQueue<some Any>) async -> TrackerImportScope? {
        let scope = TrackerImportScope(account: queue.account, profileID: ActiveProfileStore.current)
        await queue.flush()
        guard scope.isCurrent(isConnected: true, account: queue.account, pendingCount: queue.pendingCount) else {
            return nil
        }
        return scope
    }

    /// Whether fetched history may still be applied: still connected, to the
    /// same account, on the same profile, with nothing local waiting to go up.
    func isCurrent(
        isConnected: Bool,
        account: String?,
        pendingCount: Int,
        profileID: UUID? = ActiveProfileStore.current
    ) -> Bool {
        isConnected && account == self.account && pendingCount == 0 && profileID == self.profileID
    }
}

//
//  TrackerImportRun.swift
//  Lume
//
//  Whose history a tracker import may write. An import fetches the account's
//  history over the network and then applies it to the catalog; in between,
//  the viewer can disconnect, sign in to another account, switch profile, or
//  change something locally that is still on its way out. Any of those means
//  the fetched history no longer describes what it would overwrite.
//

import Foundation

/// Import and parked-progress authorization use the same identity value.
/// Outbox readiness remains an import-only gate, not part of that identity.
nonisolated extension TrackerScope {
    var account: String? {
        accountID
    }

    init(account: String?, profileID: UUID?) {
        self.init(profileID: profileID, accountID: account)
    }

    /// Taken once the outbox has been flushed: local changes go up before the
    /// history comes down, so the import can't undo them. `nil` while some are
    /// still pending (offline, or the flush failed); the import waits for the
    /// next one.
    @MainActor
    static func begin(after queue: TrackerMutationQueue<some Any>) async -> TrackerScope? {
        guard let account = queue.account, !account.isEmpty else { return nil }
        let scope = TrackerScope(account: account, profileID: ActiveProfileStore.current)
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
        isConnected && pendingCount == 0 && matches(Self(profileID: profileID, accountID: account))
    }
}

/// What a tracker history import came to.
enum TrackerImportOutcome<Summary> {
    /// Local changes are still waiting to upload, or the scope moved before
    /// the fetch: nothing was fetched.
    case deferred
    /// No token, or the fetch failed.
    case failed
    /// Fetched, but the account, profile, connection or outbox changed while
    /// it ran: the history describes something else now, so it isn't applied.
    case discarded
    case applied(Summary)
}

/// The import sequence both trackers share: flush and take the scope, get a
/// token, fetch, check the scope again, apply. The services supply the
/// provider-specific steps; the order and the gates are fixed here, where a
/// test can change the scope mid-fetch.
struct TrackerImportRun<Items, Summary> {
    var begin: () async -> TrackerScope?
    var accessToken: () async -> String?
    var fetch: (String) async throws -> Items
    /// Whether the scope taken at `begin` still holds after the fetch.
    var isCurrent: (TrackerScope) -> Bool
    /// Applies under the scope's profile; implementations re-check it there.
    var apply: (Items, TrackerScope) async -> Summary

    func perform() async -> TrackerImportOutcome<Summary> {
        guard let scope = await begin(), !Task.isCancelled else { return .deferred }
        guard let token = await accessToken() else { return .failed }
        do {
            let items = try await fetch(token)
            guard !Task.isCancelled, isCurrent(scope) else { return .discarded }
            return await .applied(apply(items, scope))
        } catch {
            return .failed
        }
    }
}

//
//  TrackerMutationQueue.swift
//  Lume
//
//  Delivers a tracker account's durable changes (watched, watchlisted) from
//  its `TrackerMutationOutbox`, shared by the Trakt and Simkl services.
//
//  Strictly oldest-first: one failure stops the drain, so a later change can
//  never overtake an earlier one for the same title. A change the service has
//  no request for is dropped rather than left to block the queue. Changes are
//  partitioned by the account's scope, so they only drain once the session
//  knows who the tokens belong to — and a remembered identity queues them,
//  while only a confirmed one (fetched with a working token) sends them.
//

import Foundation
import OSLog

@MainActor
@Observable
final class TrackerMutationQueue<Backend: TrackerAccountBackend> {
    private(set) var pendingCount = 0
    private(set) var failedCount = 0
    private(set) var isSyncing = false
    private(set) var syncError: String?
    let watchlist = TrackerWatchlistMembership()
    @ObservationIgnored var refreshWatchlist: (() -> Void)?
    @ObservationIgnored var didDeliverMutation: (() -> Void)?

    @ObservationIgnored private let session: TrackerAccountSession<Backend>
    @ObservationIgnored private let outbox: TrackerMutationOutbox
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var drainID: UUID?

    /// Takes over the session's `identityDidChange` hook: identity is what
    /// scopes and releases the queue.
    init(session: TrackerAccountSession<Backend>, outbox: TrackerMutationOutbox) {
        self.session = session
        self.outbox = outbox
        session.identityDidChange = { [weak self] identity, confirmed in
            self?.identityDidChange(identity, confirmed: confirmed)
        }
    }

    /// The connected account's partition, once its identity is known.
    var account: String? {
        guard session.isConnected, let scope = session.identity?.scope, !scope.isEmpty else { return nil }
        return scope
    }

    /// Records the user's intent and starts sending it. A no-op until the
    /// account is known.
    func enqueue(_ kind: TrackerMutation.Kind, _ target: TrackerMutation.Target, isPresent: Bool) {
        guard let account else { return }
        outbox.enqueue(kind: kind, target: target, isPresent: isPresent, account: account)
        if kind == .watchlist {
            watchlist.reset(account: account)
            watchlist.apply(target, isPresent: isPresent)
        }
        refreshStatus()
        retry()
    }

    /// Sends the connected account's queued changes. A no-op while a drain is
    /// already running.
    func retry() {
        guard drainTask == nil, let account, outbox.firstMutation(account: account) != nil else {
            refreshStatus()
            return
        }
        syncError = nil
        isSyncing = true
        let id = UUID()
        drainID = id
        drainTask = Task { [weak self] in
            await self?.drain(account: account, id: id)
        }
    }

    /// Imports must not race ahead of this device's durable intent. Await the
    /// existing drain rather than starting another delivery loop. Failed work
    /// stays queued; callers can defer their import instead of overwriting it.
    func flush() async {
        retry()
        await drainTask?.value
        refreshStatus()
    }

    func refreshStatus() {
        guard let account else {
            pendingCount = 0
            failedCount = 0
            syncError = nil
            return
        }
        let status = outbox.status(account: account)
        pendingCount = status.pendingCount
        failedCount = status.failedCount
        if status.failedCount == 0 {
            syncError = nil
        } else if syncError == nil {
            syncError = "Some \(Backend.name) changes are waiting to retry."
        }
    }

    /// Stops sending and clears the status, on disconnect. The account's
    /// queued changes stay, partitioned under its scope.
    func reset() {
        watchlist.reset(account: nil)
        drainTask?.cancel()
        drainTask = nil
        drainID = nil
        isSyncing = false
        pendingCount = 0
        failedCount = 0
        syncError = nil
    }

    private func identityDidChange(_ identity: Backend.Identity?, confirmed: Bool) {
        if let identity {
            for previous in identity.previousScopes {
                outbox.adoptMutations(from: previous, into: identity.scope)
            }
        }
        refreshStatus()
        watchlist.reset(account: account)
        if confirmed {
            retry()
            refreshWatchlist?()
        }
    }

    func isWatchlisted(_ target: TrackerMutation.Target) -> Bool {
        guard let account else { return false }
        if let intent = outbox.mutations(account: account).last(where: { $0.kind == .watchlist && $0.target == target }) {
            return intent.isPresent
        }
        return watchlist.contains(target, account: account)
    }

    func updateWatchlist(_ targets: Set<TrackerMutation.Target>, account: String, revision: UUID) {
        guard self.account == account else { return }
        var targets = targets
        for mutation in outbox.mutations(account: account) where mutation.kind == .watchlist {
            if mutation.isPresent { targets.insert(mutation.target) } else { targets.remove(mutation.target) }
        }
        watchlist.replace(with: targets, account: account, revision: revision)
    }

    private func drain(account: String, id: UUID) async {
        defer {
            if drainID == id {
                drainTask = nil
                drainID = nil
                isSyncing = false
                refreshStatus()
            }
        }

        while !Task.isCancelled, self.account == account, let mutation = outbox.firstMutation(account: account) {
            guard let accessToken = await session.validAccessToken() else {
                outbox.recordFailure(id: mutation.id, account: account)
                syncError = "Couldn't sync changes to \(Backend.name). Please try again."
                break
            }
            do {
                guard try await session.backend.deliver(mutation, accessToken: accessToken) else {
                    Logger.network.error(
                        "Discarding \(Backend.name) \(mutation.kind.rawValue) mutation it has no request for"
                    )
                    outbox.acknowledge(id: mutation.id, account: account)
                    continue
                }
                outbox.acknowledge(id: mutation.id, account: account)
                if self.account == account {
                    didDeliverMutation?()
                    watchlist.invalidate()
                    refreshWatchlist?()
                }
            } catch {
                outbox.recordFailure(id: mutation.id, account: account)
                Logger.network.warning("\(Backend.name) mutation failed: \(error)")
                syncError = "Couldn't sync changes to \(Backend.name). Please try again."
                // Replaced while its request was in flight, it is no longer the
                // head: carry on with the newer intent. Otherwise keep strict
                // FIFO and wait for a retry.
                if outbox.contains(id: mutation.id, account: account) {
                    break
                }
            }
        }
    }
}

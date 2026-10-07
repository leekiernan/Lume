//
//  TrackerMutationQueueTests.swift
//  LumeTests
//
//  The shared durable-change queue: strict oldest-first delivery, per-account
//  partitions, and what the session's identity releases.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct TrackerMutationQueueTests {
    @Test func `flush waits for pending delivery before an import can start`() async {
        let harness = await connected()
        harness.queue.enqueue(.history, .movie(tmdbID: 41), isPresent: true)
        await harness.queue.flush()
        #expect(!harness.queue.isSyncing)
        #expect(harness.queue.pendingCount == 0)
        #expect(harness.tracker.deliveryAttempts == [.movie(tmdbID: 41)])
    }

    @Test func `flush keeps failed intent so an import can defer`() async {
        let harness = await connected()
        harness.tracker.deliveryResponses = [.failed]
        harness.queue.enqueue(.history, .movie(tmdbID: 42), isPresent: false)
        await harness.queue.flush()
        #expect(!harness.queue.isSyncing)
        #expect(harness.queue.pendingCount == 1)
        #expect(harness.queue.failedCount == 1)
    }

    private struct Harness {
        let tracker: FakeTracker
        let session: TrackerAccountSession<FakeBackend>
        let queue: TrackerMutationQueue<FakeBackend>
        let outbox: TrackerMutationOutbox
    }

    /// A connected session whose identity is confirmed, over a private outbox.
    private func connected(identity: FakeIdentity = alice, seed: ((TrackerMutationOutbox) -> Void)? = nil) async -> Harness {
        let tracker = FakeTracker()
        tracker.storedTokens = FakeTokens(accessToken: "a", refreshToken: "r", issuedAt: 1)
        tracker.identityResponses = [identity]
        let defaults = UserDefaults(suiteName: "TrackerMutationQueueTests.\(UUID().uuidString)")!
        let outbox = TrackerMutationOutbox(defaults: defaults, storageKey: FakeBackend.outboxStorageKey)
        seed?(outbox)
        let session = TrackerAccountSession(backend: FakeBackend(tracker: tracker), identityRetryDelay: .milliseconds(20))
        let queue = TrackerMutationQueue(session: session, outbox: outbox)
        _ = await session.restore()
        return Harness(tracker: tracker, session: session, queue: queue, outbox: outbox)
    }

    private func settle(_ queue: TrackerMutationQueue<FakeBackend>) async throws {
        try await waitUntil { !queue.isSyncing }
    }

    @Test func `restored watchlist intent overrides a server snapshot until delivery`() async throws {
        let target = TrackerMutation.Target.movie(tmdbID: 42)
        let harness = await connected { outbox in
            outbox.enqueue(kind: .watchlist, target: target, isPresent: false, account: alice.scope)
        }
        harness.tracker.deliveryResponses = [.failed]
        let revision = harness.queue.watchlist.revision
        harness.queue.updateWatchlist([target], account: alice.scope, revision: revision)
        #expect(!harness.queue.isWatchlisted(target))
        try await settle(harness.queue)
        #expect(!harness.queue.isWatchlisted(target))
    }

    @Test func `successful watchlist delivery keeps optimistic membership and invalidates older reads`() async throws {
        let harness = await connected()
        let target = TrackerMutation.Target.movie(tmdbID: 42)
        harness.queue.enqueue(.watchlist, target, isPresent: true)
        let revision = harness.queue.watchlist.revision
        try await settle(harness.queue)
        harness.queue.updateWatchlist([], account: alice.scope, revision: revision)
        #expect(harness.queue.isWatchlisted(target))
        #expect(harness.queue.pendingCount == 0)
    }

    @Test func `changes go out oldest first`() async throws {
        let harness = await connected()
        harness.queue.enqueue(.history, .movie(tmdbID: 1), isPresent: true)
        harness.queue.enqueue(.watchlist, .show(tmdbID: 2), isPresent: true)
        try await settle(harness.queue)

        #expect(harness.tracker.deliveryAttempts == [.movie(tmdbID: 1), .show(tmdbID: 2)])
        #expect(harness.queue.pendingCount == 0)
    }

    @Test func `a failure stops the queue so nothing overtakes it`() async throws {
        let harness = await connected()
        harness.tracker.deliveryResponses = [.failed]
        harness.queue.enqueue(.history, .movie(tmdbID: 1), isPresent: true)
        try await settle(harness.queue)
        harness.queue.enqueue(.history, .movie(tmdbID: 2), isPresent: true)
        try await settle(harness.queue)

        // The retry sends the failed head first, then the newer change.
        #expect(harness.tracker.deliveryAttempts == [.movie(tmdbID: 1), .movie(tmdbID: 1), .movie(tmdbID: 2)])
        #expect(harness.queue.pendingCount == 0)
        #expect(harness.queue.syncError == nil)
    }

    @Test func `a failed head is reported and kept`() async throws {
        let harness = await connected()
        harness.tracker.deliveryResponses = [.failed]
        harness.queue.enqueue(.history, .movie(tmdbID: 1), isPresent: true)
        try await settle(harness.queue)

        #expect(harness.queue.pendingCount == 1)
        #expect(harness.queue.failedCount == 1)
        #expect(harness.queue.syncError == "Couldn't sync changes to Fake. Please try again.")
    }

    @Test func `a change the service can't send is dropped, not left blocking`() async throws {
        let harness = await connected()
        harness.tracker.deliveryResponses = [.unsupported]
        harness.queue.enqueue(.watchlist, .episode(showTMDBID: 1, season: 1, episode: 1), isPresent: true)
        harness.queue.enqueue(.history, .movie(tmdbID: 2), isPresent: true)
        try await settle(harness.queue)

        #expect(harness.tracker.deliveryAttempts.last == .movie(tmdbID: 2))
        #expect(harness.queue.pendingCount == 0)
    }

    @Test func `changes filed under an earlier scope move to the account and go out`() async throws {
        var identity = alice
        identity.previous = ["legacy:alice"]
        let harness = await connected(identity: identity) { outbox in
            outbox.enqueue(kind: .history, target: .movie(tmdbID: 7), isPresent: true, account: "legacy:alice")
        }
        try await settle(harness.queue)

        #expect(harness.tracker.deliveryAttempts == [.movie(tmdbID: 7)])
        #expect(harness.outbox.mutations(account: "legacy:alice").isEmpty)
    }

    @Test func `nothing is queued before the account is known`() throws {
        let tracker = FakeTracker()
        let defaults = try #require(UserDefaults(suiteName: "TrackerMutationQueueTests.\(UUID().uuidString)"))
        let outbox = TrackerMutationOutbox(defaults: defaults, storageKey: FakeBackend.outboxStorageKey)
        let session = TrackerAccountSession(backend: FakeBackend(tracker: tracker))
        let queue = TrackerMutationQueue(session: session, outbox: outbox)

        queue.enqueue(.history, .movie(tmdbID: 1), isPresent: true)

        #expect(queue.account == nil)
        #expect(queue.pendingCount == 0)
    }

    @Test func `reset clears the status but keeps the account's changes`() async throws {
        let harness = await connected()
        harness.tracker.deliveryResponses = [.failed]
        harness.queue.enqueue(.history, .movie(tmdbID: 1), isPresent: true)
        try await settle(harness.queue)

        harness.queue.reset()

        #expect(harness.queue.pendingCount == 0)
        #expect(harness.queue.syncError == nil)
        #expect(harness.outbox.mutations(account: alice.scope).count == 1)
    }
}

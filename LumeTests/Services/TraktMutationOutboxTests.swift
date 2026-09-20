import Foundation
@testable import Lume
import Testing

@MainActor
struct TraktMutationOutboxTests {
    private struct LegacyMutation: Codable {
        let id: UUID
        let target: TraktMutation.Target
        let watched: Bool
        let enqueuedAt: Date
        let attemptCount: Int
        let lastAttemptAt: Date?
    }

    private struct LegacyState: Codable {
        let accounts: [String: [LegacyMutation]]
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "TraktMutationOutboxTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test func `latest intent replaces an older mutation and moves to the tail`() throws {
        let defaults = try makeDefaults()
        let outbox = TraktMutationOutbox(defaults: defaults)
        let movie = TraktMutation.Target.movie(tmdbID: 42)
        let episode = TraktMutation.Target.episode(showTMDBID: 84, season: 1, episode: 2)

        outbox.enqueue(kind: .history, target: movie, isPresent: true, account: "Viewer")
        outbox.enqueue(kind: .history, target: episode, isPresent: true, account: "Viewer")
        outbox.enqueue(kind: .history, target: movie, isPresent: false, account: "Viewer")

        let mutations = outbox.mutations(account: "viewer")
        #expect(mutations.map(\.target) == [episode, movie])
        #expect(mutations.last?.isPresent == false)
    }

    @Test func `history and watchlist intent for one movie remain independent`() throws {
        let defaults = try makeDefaults()
        let outbox = TraktMutationOutbox(defaults: defaults)
        let movie = TraktMutation.Target.movie(tmdbID: 42)

        outbox.enqueue(kind: .history, target: movie, isPresent: true, account: "viewer")
        outbox.enqueue(kind: .watchlist, target: movie, isPresent: true, account: "viewer")
        outbox.enqueue(kind: .history, target: movie, isPresent: false, account: "viewer")

        let mutations = outbox.mutations(account: "viewer")
        #expect(mutations.map(\.kind) == [.watchlist, .history])
        #expect(mutations.map(\.isPresent) == [true, false])
    }

    @Test func `accounts have isolated queues`() throws {
        let defaults = try makeDefaults()
        let outbox = TraktMutationOutbox(defaults: defaults)

        outbox.enqueue(kind: .history, target: .movie(tmdbID: 1), isPresent: true, account: "Alice")
        outbox.enqueue(kind: .history, target: .movie(tmdbID: 2), isPresent: true, account: "Bob")

        #expect(outbox.mutations(account: "ALICE").map(\.target) == [.movie(tmdbID: 1)])
        #expect(outbox.mutations(account: "bob").map(\.target) == [.movie(tmdbID: 2)])
    }

    @Test func `acknowledging an in flight mutation preserves its replacement`() throws {
        let defaults = try makeDefaults()
        let outbox = TraktMutationOutbox(defaults: defaults)
        let target = TraktMutation.Target.movie(tmdbID: 42)
        let inFlight = outbox.enqueue(kind: .history, target: target, isPresent: true, account: "viewer")
        let replacement = outbox.enqueue(kind: .history, target: target, isPresent: false, account: "viewer")

        outbox.acknowledge(id: inFlight.id, account: "viewer")

        #expect(outbox.mutations(account: "viewer") == [replacement])
    }

    @Test func `failure state survives a new outbox instance`() throws {
        let defaults = try makeDefaults()
        let first = TraktMutationOutbox(defaults: defaults)
        let mutation = first.enqueue(
            kind: .watchlist,
            target: .show(tmdbID: 42),
            isPresent: true,
            account: "viewer"
        )
        first.recordFailure(id: mutation.id, account: "viewer")

        let restored = TraktMutationOutbox(defaults: defaults)

        #expect(restored.status(account: "viewer") == TraktMutationStatus(pendingCount: 1, failedCount: 1))
        #expect(restored.firstMutation(account: "viewer")?.attemptCount == 1)
        #expect(restored.firstMutation(account: "viewer")?.lastAttemptAt != nil)
    }

    @Test func `history-only outbox data migrates without losing intent`() throws {
        let defaults = try makeDefaults()
        let key = "legacy.outbox"
        let id = UUID()
        let legacy = LegacyMutation(
            id: id,
            target: .movie(tmdbID: 42),
            watched: true,
            enqueuedAt: Date(timeIntervalSinceReferenceDate: 100),
            attemptCount: 1,
            lastAttemptAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        try defaults.set(
            JSONEncoder().encode(LegacyState(accounts: ["viewer": [legacy]])),
            forKey: key
        )

        let restored = TraktMutationOutbox(defaults: defaults, storageKey: key)
        let mutation = try #require(restored.firstMutation(account: "viewer"))

        #expect(mutation.id == id)
        #expect(mutation.kind == .history)
        #expect(mutation.isPresent)
        #expect(mutation.attemptCount == 1)
    }

    @Test func `account identity is cached without storing OAuth credentials`() throws {
        let defaults = try makeDefaults()
        let identity = TraktAccountIdentity(username: "viewer", scope: "trakt:42")

        TraktAccountIdentityStore.save(identity, defaults: defaults)
        #expect(TraktAccountIdentityStore.load(defaults: defaults) == identity)

        TraktAccountIdentityStore.clear(defaults: defaults)
        #expect(TraktAccountIdentityStore.load(defaults: defaults) == nil)
    }

    @Test func `trakt user decodes stable account id`() throws {
        let data = Data(#"{"username":"viewer","name":"Viewer","ids":{"trakt":42}}"#.utf8)

        let user = try JSONDecoder().decode(TraktUser.self, from: data)

        #expect(user.username == "viewer")
        #expect(user.ids?.trakt == 42)
    }
}

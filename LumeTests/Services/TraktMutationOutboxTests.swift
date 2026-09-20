import Foundation
@testable import Lume
import Testing

@MainActor
struct TraktMutationOutboxTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "TraktMutationOutboxTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test func `latest intent replaces an older mutation and moves to the tail`() throws {
        let defaults = try makeDefaults()
        let outbox = TraktMutationOutbox(defaults: defaults)
        let movie = TraktHistoryMutation.Target.movie(tmdbID: 42)
        let episode = TraktHistoryMutation.Target.episode(showTMDBID: 84, season: 1, episode: 2)

        outbox.enqueue(target: movie, watched: true, account: "Viewer")
        outbox.enqueue(target: episode, watched: true, account: "Viewer")
        outbox.enqueue(target: movie, watched: false, account: "Viewer")

        let mutations = outbox.mutations(account: "viewer")
        #expect(mutations.map(\.target) == [episode, movie])
        #expect(mutations.last?.watched == false)
    }

    @Test func `accounts have isolated queues`() throws {
        let defaults = try makeDefaults()
        let outbox = TraktMutationOutbox(defaults: defaults)

        outbox.enqueue(target: .movie(tmdbID: 1), watched: true, account: "Alice")
        outbox.enqueue(target: .movie(tmdbID: 2), watched: true, account: "Bob")

        #expect(outbox.mutations(account: "ALICE").map(\.target) == [.movie(tmdbID: 1)])
        #expect(outbox.mutations(account: "bob").map(\.target) == [.movie(tmdbID: 2)])
    }

    @Test func `acknowledging an in flight mutation preserves its replacement`() throws {
        let defaults = try makeDefaults()
        let outbox = TraktMutationOutbox(defaults: defaults)
        let target = TraktHistoryMutation.Target.movie(tmdbID: 42)
        let inFlight = outbox.enqueue(target: target, watched: true, account: "viewer")
        let replacement = outbox.enqueue(target: target, watched: false, account: "viewer")

        outbox.acknowledge(id: inFlight.id, account: "viewer")

        #expect(outbox.mutations(account: "viewer") == [replacement])
    }

    @Test func `failure state survives a new outbox instance`() throws {
        let defaults = try makeDefaults()
        let first = TraktMutationOutbox(defaults: defaults)
        let mutation = first.enqueue(target: .movie(tmdbID: 42), watched: true, account: "viewer")
        first.recordFailure(id: mutation.id, account: "viewer")

        let restored = TraktMutationOutbox(defaults: defaults)

        #expect(restored.status(account: "viewer") == TraktMutationStatus(pendingCount: 1, failedCount: 1))
        #expect(restored.firstMutation(account: "viewer")?.attemptCount == 1)
        #expect(restored.firstMutation(account: "viewer")?.lastAttemptAt != nil)
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

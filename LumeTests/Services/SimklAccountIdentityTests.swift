import Foundation
@testable import Lume
import Testing

/// The remembered Simkl identity that keeps an offline cold launch connected,
/// so watched changes still queue under the right account.
@MainActor
struct SimklAccountIdentityTests {
    private func makeDefaults() throws -> UserDefaults {
        let name = "SimklAccountIdentityTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    private func settings(_ json: String) throws -> SimklUserSettings {
        try JSONDecoder().decode(SimklUserSettings.self, from: Data(json.utf8))
    }

    @Test func `scope uses the stable account id`() throws {
        let identity = try SimklAccountIdentity(settings: settings(
            #"{"user":{"name":"Viewer"},"account":{"id":42,"timezone":"UTC"}}"#
        ))
        #expect(identity.username == "Viewer")
        #expect(identity.scope == "simkl:42")
        #expect(identity.legacyScope == "viewer")
    }

    @Test func `scope falls back to the normalized username`() throws {
        let identity = try SimklAccountIdentity(settings: settings(#"{"user":{"name":" Viewer "}}"#))
        #expect(identity.scope == "username:viewer")
    }

    @Test func `identity round-trips without storing OAuth credentials`() throws {
        let defaults = try makeDefaults()
        let identity = SimklAccountIdentity(username: "Viewer", scope: "simkl:42")

        SimklAccountIdentityStore.save(identity, defaults: defaults)
        #expect(SimklAccountIdentityStore.load(defaults: defaults) == identity)

        SimklAccountIdentityStore.clear(defaults: defaults)
        #expect(SimklAccountIdentityStore.load(defaults: defaults) == nil)
    }

    @Test func `changes queued under the username scope are adopted`() throws {
        let defaults = try makeDefaults()
        let outbox = TrackerMutationOutbox(defaults: defaults, storageKey: "simkl.test")
        let movie = TrackerMutation.Target.movie(tmdbID: 1)
        let episode = TrackerMutation.Target.episode(showTMDBID: 2, season: 1, episode: 1)

        outbox.enqueue(target: movie, watched: true, account: "viewer")
        outbox.enqueue(target: episode, watched: true, account: "viewer")
        outbox.enqueue(target: movie, watched: false, account: "simkl:42")

        outbox.adoptMutations(from: "viewer", into: "simkl:42")

        #expect(outbox.mutations(account: "viewer").isEmpty)
        let adopted = outbox.mutations(account: "simkl:42")
        // The legacy movie change is superseded by the newer one; the episode
        // is older than it, so it goes first.
        #expect(adopted.map(\.target) == [episode, movie])
        #expect(adopted.last?.isPresent == false)

        // Persisted: a fresh outbox over the same defaults sees the move.
        let reloaded = TrackerMutationOutbox(defaults: defaults, storageKey: "simkl.test")
        #expect(reloaded.mutations(account: "simkl:42").count == 2)
    }
}

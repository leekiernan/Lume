import Foundation
@testable import Lume
import Testing

@MainActor
struct AutoSyncReconnectionTests {
    @Test func `reconnection filters failures and all queue owners and resets only affected attempts`() {
        let retry = UUID(), cover = UUID(), pending = UUID(), background = UUID(), unrelated = UUID(), healthy = UUID()
        let failed: Set<UUID> = [retry, cover, pending, background, unrelated]
        let plan = AutoSync.ReconnectionPlan(reconnectedIDs: [retry, cover, pending, background, healthy], failedIDs: failed,
                                             queuedIDs: [cover, pending, background])
        #expect(plan.enqueueIDs == [retry])
        #expect(plan.resetIDs == [retry, cover, pending, background])
        var attempts = failed.union([healthy])
        var ledger = AutoSync.RepairLedger()
        for id in attempts {
            ledger.record([.movies, .liveTV], for: id)
        }
        plan.resetAttempts(&attempts, ledger: &ledger)
        #expect(attempts == [unrelated, healthy])
        for id in plan.resetIDs {
            #expect(ledger.untried([.movies, .liveTV], for: id) == [.movies, .liveTV])
        }
        #expect(ledger.untried([.movies], for: unrelated).isEmpty)
        #expect(ledger.untried([.movies], for: healthy).isEmpty)
        let empty = AutoSync.ReconnectionPlan(reconnectedIDs: [], failedIDs: failed, queuedIDs: [])
        #expect(empty.resetIDs.isEmpty && empty.enqueueIDs.isEmpty)
    }

    @Test func `reconnection wiring allows one new attempt but not healthy or queued playlists`() throws {
        let retry = Playlist(name: "Failed", serverURL: "https://example.test", username: "u", password: "p")
        let healthy = Playlist(name: "Healthy", serverURL: "https://example.test", username: "u", password: "p")
        let queued = Playlist(name: "Cover", serverURL: "https://example.test", username: "u", password: "p")
        retry.syncStatus = .error
        retry.lastSyncDate = Date()
        queued.syncStatus = .error
        let playlists = [retry, healthy, queued]
        let reconnect = AutoSync.ReconnectionPlan(playlists: playlists, reconnectedIDs: Set(playlists.map(\.id)), queuedIDs: [queued.id])
        #expect(playlists.filter { reconnect.enqueueIDs.contains($0.id) }.map(\.id) == [retry.id])
        var attempts: Set<UUID> = [retry.id, healthy.id, queued.id]
        var ledger = AutoSync.RepairLedger()
        ledger.record([.liveTV], for: retry.id)
        func request() -> AutoSync.Plan? {
            AutoSync.plan(.init(candidate: retry.autoSyncCandidate(activeID: retry.id.uuidString), playlistID: retry.id,
                                frequency: .daily, alreadyStarted: attempts.contains(retry.id), staleAreas: [.liveTV], supportsAreaRepair: true),
                          ledger: ledger, areasWithRows: { [] })
        }
        #expect(request() == nil)
        reconnect.resetAttempts(&attempts, ledger: &ledger)
        let next = try #require(request())
        attempts.insert(retry.id)
        ledger.record(next.repairedAreas, for: retry.id)
        #expect(request() == nil)
        #expect(attempts.contains(healthy.id))
    }
}

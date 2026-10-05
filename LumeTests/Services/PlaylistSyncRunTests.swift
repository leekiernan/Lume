import Foundation
@testable import Lume
import SwiftData
import Testing

@Suite(.globalState)
@MainActor
struct PlaylistSyncRunTests {
    init() {
        clearM3UDigests()
    }

    private func makePlaylist(container: ModelContainer, fileURL: URL) throws -> Playlist {
        let context = ModelContext(container)
        let playlist = Playlist(name: "Test M3U", m3uURL: fileURL.absoluteString)
        context.insert(playlist)
        try context.save()
        return playlist
    }

    private func playlistFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m3u")
        try """
        #EXTM3U
        #EXTINF:-1 group-title="VOD | Action",A Movie
        http://example.com/movie/u/p/1.mp4
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func `shared runner reports one success for a completed refresh`() async throws {
        let container = try makeTestContainer()
        let fileURL = try playlistFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)
        let notifications = SyncCompletionNotifications()
        let plan = PlaylistSyncPlan(sourceType: .m3u, enabledAreas: [.movies, .series])

        try await PlaylistSyncRun.perform(playlist, container: container, plan: plan, notifications: notifications)

        #expect(notifications.pending.count == 1)
        #expect(notifications.pending.first?.outcome == .succeeded)
        #expect(notifications.pending.first?.subject == .playlist(playlist.id, name: playlist.name))
    }

    @Test func `shared runner reports one failure without swallowing the error`() async throws {
        let container = try makeTestContainer()
        let playlist = try makePlaylist(
            container: container,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).m3u")
        )
        let notifications = SyncCompletionNotifications()
        let plan = PlaylistSyncPlan(sourceType: .m3u, enabledAreas: [.movies, .series])

        do {
            try await PlaylistSyncRun.perform(playlist, container: container, plan: plan, notifications: notifications)
            Issue.record("The missing playlist should fail")
        } catch {
            #expect(notifications.pending.count == 1)
            #expect(notifications.pending.first?.outcome == .failed)
        }
    }

    @Test func `shared runner keeps a cancelled refresh silent`() async throws {
        let container = try makeTestContainer()
        let fileURL = try playlistFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let playlist = try makePlaylist(container: container, fileURL: fileURL)
        let notifications = SyncCompletionNotifications()
        let plan = PlaylistSyncPlan(sourceType: .m3u, enabledAreas: [.movies, .series])

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await PlaylistSyncRun.perform(playlist, container: container, plan: plan, notifications: notifications)
                Issue.record("Cancellation should propagate to the playlist runner")
            } catch {
                #expect(Task.isCancelled)
            }
        }
        await task.value
        #expect(notifications.pending.isEmpty)
    }
}

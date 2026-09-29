//
//  ExampleProviderTests.swift
//  LumeTests
//
//  The unit-test host syncs `ExampleProvider` at launch. This runs the same
//  sync over its playlist, so a fixture change that stops it importing — or
//  sorts an entry into the wrong kind — fails here instead of leaving the host
//  on an empty catalog or a "Sync failed" cover.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@Suite(.globalState)
struct ExampleProviderTests {
    @Test func `the example provider imports one of each kind`() async throws {
        let container = try makeTestContainer()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m3u")
        try Data(ExampleProvider.m3u.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // Its own id, not `ExampleProvider.playlistID`: the host is syncing that
        // one alongside, and the two would share its fingerprints.
        let playlist = Playlist(name: "Example Provider", m3uURL: file.absoluteString)
        let playlistID = playlist.id
        let seedContext = ModelContext(container)
        seedContext.insert(playlist)
        try seedContext.save()
        defer {
            M3UDigestStore.remove(playlistId: playlistID)
            SweepSkipDefaults.removeAll(playlistId: playlistID)
        }

        try await ContentSyncManager(modelContainer: container).syncPlaylist(playlist)

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<LiveStream>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Movie>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<Series>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 3)
    }
}

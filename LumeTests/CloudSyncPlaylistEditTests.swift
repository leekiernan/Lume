//
//  CloudSyncPlaylistEditTests.swift
//  LumeTests
//
//  A playlist edited after the engine's first pass must still reach the other
//  side. The engine lives for the whole session, so these run two passes on
//  one engine with the edit saved from another context in between — the way
//  Settings (the view context) and a CloudKit import (the mirroring
//  delegate's context) actually write.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState)
struct CloudSyncPlaylistEditTests {
    private func freshShadow() -> CloudSyncShadow {
        CloudSyncShadow(defaults: UserDefaults(suiteName: "cloudsync.test.\(UUID().uuidString)")!)
    }

    /// The playlist as the store holds it. The main context's own object
    /// only catches up with the engine's save on a later merge.
    private func stored(in container: ModelContainer) throws -> Playlist {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Playlist>()).first)
    }

    @Test func `a local URL edit after the first pass is pushed`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let playlist = Playlist(name: "IPTV", serverURL: "http://old", username: "u", password: "p")
        ctx.insert(playlist)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        await engine.reconcile()

        playlist.serverURL = "http://new"
        try ctx.save()
        let result = await engine.reconcile()

        #expect(result.playlistsPushed == 1)
        let mirror = try #require(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).first)
        #expect(mirror.serverURL == "http://new")
    }

    @Test func `a cloud URL edit after the first pass is pulled`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let playlist = Playlist(name: "IPTV", serverURL: "http://old", username: "u", password: "p")
        ctx.insert(playlist)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        await engine.reconcile()

        let mirror = try #require(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).first)
        mirror.serverURL = "http://new"
        try ctx.save()
        let result = await engine.reconcile()

        #expect(result.playlistsPulled == 1)
        #expect(result.playlistsReconnected == [playlist.id])
        #expect(try stored(in: container).serverURL == "http://new")
    }

    @Test func `a pulled rename is not a reconnection`() async throws {
        let container = try makeProfileTestContainer()
        let ctx = container.mainContext
        let playlist = Playlist(name: "IPTV", serverURL: "http://same", username: "u", password: "p")
        ctx.insert(playlist)
        try ctx.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        await engine.reconcile()

        let mirror = try #require(try ctx.fetch(FetchDescriptor<SyncedPlaylist>()).first)
        mirror.name = "Renamed"
        try ctx.save()
        let result = await engine.reconcile()

        #expect(result.playlistsPulled == 1)
        #expect(result.playlistsReconnected.isEmpty)
        #expect(try stored(in: container).name == "Renamed")
    }
}

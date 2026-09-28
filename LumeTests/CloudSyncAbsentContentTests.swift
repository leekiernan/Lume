//
//  CloudSyncAbsentContentTests.swift
//  LumeTests
//
//  A title's watched state missing locally only means the user cleared it
//  when the title itself is still in the catalog. A row removed from under
//  the state — a series pruned by a catalog sync — must not delete the iCloud
//  record every device reads it from.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState)
struct CloudSyncAbsentContentTests {
    private func freshShadow() -> CloudSyncShadow {
        CloudSyncShadow(defaults: UserDefaults(suiteName: "cloudsync.absent.test.\(UUID().uuidString)")!)
    }

    /// A playlist with a watched movie and another title (so the catalog is
    /// never empty), reconciled once so the cloud record and shadow exist.
    private func syncedWatchedMovie() async throws
        -> (context: ModelContext, engine: CloudSyncEngine, movieID: String)
    {
        let container = try makeProfileTestContainer()
        let context = container.mainContext
        let playlist = Playlist(name: "IPTV", serverURL: "http://x", username: "u", password: "p")
        context.insert(playlist)
        let movieID = "\(playlist.id.uuidString)-movie-1"
        let watched = Movie(id: movieID, streamId: 1, name: "Watched")
        watched.isWatched = true
        context.insert(watched)
        context.insert(Movie(id: "\(playlist.id.uuidString)-movie-2", streamId: 2, name: "Other"))
        try context.save()

        let engine = CloudSyncEngine(container: container, shadow: freshShadow())
        _ = await engine.reconcile()
        #expect(try context.fetch(FetchDescriptor<UserContentState>()).count == 1)
        return (context, engine, movieID)
    }

    private func movie(_ id: String, in context: ModelContext) throws -> Movie? {
        try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })).first
    }

    @Test func `a pruned title keeps its cloud state, and gets it back when it returns`() async throws {
        let (context, engine, movieID) = try await syncedWatchedMovie()

        // A catalog sync prunes the title.
        if let row = try movie(movieID, in: context) { context.delete(row) }
        try context.save()
        let pruned = await engine.reconcile()

        #expect(try context.fetch(FetchDescriptor<UserContentState>()).count == 1)
        #expect(pruned.contentPending >= 1)

        // The provider lists it again; it arrives unwatched.
        context.insert(Movie(id: movieID, streamId: 1, name: "Watched"))
        try context.save()
        _ = await engine.reconcile()

        #expect(try movie(movieID, in: context)?.isWatched == true)
    }

    @Test func `unmarking a title still clears it everywhere`() async throws {
        let (context, engine, movieID) = try await syncedWatchedMovie()

        try movie(movieID, in: context)?.isWatched = false
        try context.save()
        _ = await engine.reconcile()

        #expect(try context.fetch(FetchDescriptor<UserContentState>()).isEmpty)
    }
}

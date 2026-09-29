//
//  CloudSyncAbsentContentTests.swift
//  LumeTests
//
//  A title's state is cleared only by the viewer clearing it. A catalog row
//  removed or re-created from under the state — a series pruned by a catalog
//  sync, a playlist resync — and a cloud record this device doesn't have
//  (not imported yet, lost) are not decisions, and must not clear anything.
//  See `ContentIntentMerge`.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
@Suite(.globalState)
struct CloudSyncAbsentContentTests {
    private struct Synced {
        let context: ModelContext
        let engine: CloudSyncEngine
        let clears: ContentClearLedger
        let movieID: String
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cloudsync.absent.test.\(UUID().uuidString)")!
    }

    /// A playlist with a watched movie and another title (so the catalog is
    /// never empty), reconciled once so the cloud record and shadow exist.
    private func syncedWatchedMovie() async throws -> Synced {
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

        let clears = ContentClearLedger(defaults: freshDefaults())
        let engine = CloudSyncEngine(container: container, shadow: CloudSyncShadow(defaults: freshDefaults()), clears: clears)
        _ = await engine.reconcile()
        #expect(try records(in: context).count == 1)
        return Synced(context: context, engine: engine, clears: clears, movieID: movieID)
    }

    private func movie(_ id: String, in context: ModelContext) throws -> Movie? {
        try context.fetch(FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })).first
    }

    private func records(in context: ModelContext) throws -> [UserContentState] {
        try context.fetch(FetchDescriptor<UserContentState>())
    }

    @Test func `a pruned title keeps its cloud state, and gets it back when it returns`() async throws {
        let synced = try await syncedWatchedMovie()
        let context = synced.context

        // A catalog sync prunes the title.
        if let row = try movie(synced.movieID, in: context) { context.delete(row) }
        try context.save()
        _ = await synced.engine.reconcile()
        #expect(try records(in: context).first?.isWatched == true)

        // The provider lists it again; it arrives unwatched.
        context.insert(Movie(id: synced.movieID, streamId: 1, name: "Watched"))
        try context.save()
        _ = await synced.engine.reconcile()

        #expect(try movie(synced.movieID, in: context)?.isWatched == true)
    }

    /// A row reset in place — no clear recorded — is a resync, not the viewer.
    @Test func `a blank row the viewer didn't clear gets its state back`() async throws {
        let synced = try await syncedWatchedMovie()

        try movie(synced.movieID, in: synced.context)?.isWatched = false
        try synced.context.save()
        _ = await synced.engine.reconcile()

        #expect(try movie(synced.movieID, in: synced.context)?.isWatched == true)
        #expect(try records(in: synced.context).first?.isWatched == true)
    }

    /// The viewer's clear reaches the cloud as a cleared record, not a
    /// deletion another device couldn't tell from one not imported yet.
    @Test func `unmarking a title writes a cleared record`() async throws {
        let synced = try await syncedWatchedMovie()

        try movie(synced.movieID, in: synced.context)?.isWatched = false
        synced.clears.record(synced.movieID)
        try synced.context.save()
        _ = await synced.engine.reconcile()

        let records = try records(in: synced.context)
        #expect(records.count == 1)
        #expect(records.first?.isWatched == false)
        #expect(try movie(synced.movieID, in: synced.context)?.isWatched == false)
        // Pushed and saved: the ledger forgets it.
        #expect(synced.clears.ids.isEmpty)
    }

    /// Another device's clear arrives as a cleared record and clears here.
    @Test func `a cleared record from another device clears this one`() async throws {
        let synced = try await syncedWatchedMovie()

        let record = try #require(try records(in: synced.context).first)
        record.isWatched = false
        record.updatedAt = Date()
        try synced.context.save()
        _ = await synced.engine.reconcile()

        #expect(try movie(synced.movieID, in: synced.context)?.isWatched == false)
    }

    /// A record this device can't see — not imported yet, or lost — says
    /// nothing: the state stays, and the record is written again.
    @Test func `a missing cloud record doesn't clear this device`() async throws {
        let synced = try await syncedWatchedMovie()

        for record in try records(in: synced.context) {
            synced.context.delete(record)
        }
        try synced.context.save()
        _ = await synced.engine.reconcile()

        #expect(try movie(synced.movieID, in: synced.context)?.isWatched == true)
        #expect(try records(in: synced.context).first?.isWatched == true)
    }

    /// A clear recorded while a pass runs belongs to the next one.
    @Test func `the ledger keeps clears the pass didn't read`() async throws {
        let synced = try await syncedWatchedMovie()
        synced.clears.record("later")
        _ = await synced.engine.reconcile()
        // `later` was in the snapshot this pass read — so gone; one recorded
        // afterwards stays.
        synced.clears.record("after")
        #expect(synced.clears.ids == ["after"])
    }
}

/// The merge on its own.
struct ContentIntentMergeTests {
    private let watched = ContentStateValues(
        watchProgress: 0, isWatched: true, lastWatchedDate: nil,
        isFavorite: false, addedToWatchlistDate: nil, favoriteOrder: nil
    )

    @Test func `absence is never a clear`() {
        // A missing cloud record re-creates it from local.
        #expect(ContentIntentMerge.reconcile(local: .state(watched), cloud: .absent, shadow: watched) == .pushToCloud(watched))
        // A blank row takes the cloud's state back.
        #expect(ContentIntentMerge.reconcile(local: .blank, cloud: .state(watched), shadow: watched) == .pullToLocal(watched))
        // Neither side knows anything: leave it.
        #expect(ContentIntentMerge.reconcile(local: .blank, cloud: .absent, shadow: watched) == .noChange)
    }

    @Test func `the viewer's clear is written, not deleted`() {
        #expect(ContentIntentMerge.reconcile(local: .clearedByUser, cloud: .state(watched), shadow: watched) == .pushToCloud(.empty))
        #expect(ContentIntentMerge.reconcile(local: .clearedByUser, cloud: .absent, shadow: watched) == .pushToCloud(.empty))
        // A clear of something never synced has nothing to say.
        #expect(ContentIntentMerge.reconcile(local: .clearedByUser, cloud: .absent, shadow: nil) == .noChange)
    }

    @Test func `another device's clear is pulled`() {
        #expect(ContentIntentMerge.reconcile(local: .state(watched), cloud: .state(.empty), shadow: watched) == .pullToLocal(.empty))
    }

    @Test func `a row this device doesn't have waits for it`() {
        #expect(ContentIntentMerge.reconcile(local: .missingRow, cloud: .state(watched), shadow: nil) == .pending)
        #expect(ContentIntentMerge.reconcile(local: .missingRow, cloud: .state(watched), shadow: watched) == .noChange)
        #expect(ContentIntentMerge.reconcile(local: .missingRow, cloud: .absent, shadow: watched) == .noChange)
    }

    /// Unchanged from before: a clear against an edit on the other side keeps
    /// the edit (never lose a favourite or progress to a conflict).
    @Test func `a clear against an edit keeps the edit`() {
        let favourite = ContentStateValues(
            watchProgress: 0, isWatched: true, lastWatchedDate: nil,
            isFavorite: true, addedToWatchlistDate: nil, favoriteOrder: nil
        )
        #expect(ContentIntentMerge.reconcile(local: .clearedByUser, cloud: .state(favourite), shadow: watched) == .writeBoth(favourite))
    }
}

//
//  StalkerUpsertTests.swift
//  LumeTests
//
//  The Stalker VOD/series upsert: dirty-checked like the Xtream and m3u
//  upserts, and never moving an already-filed title out of its category when
//  the portal (a search hit, an "All" walk) names none.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct StalkerUpsertTests {
    private func item(_ json: String) throws -> StalkerVODItem {
        try JSONDecoder().decode(StalkerVODItem.self, from: Data(json.utf8))
    }

    @Test func `a supplied category always wins`() {
        #expect(ContentSyncManager.stalkerCategoryId("7", current: "p-vod-3", playlistPrefix: "p-vod-") == "p-vod-7")
        #expect(ContentSyncManager.stalkerCategoryId("7", current: nil, playlistPrefix: "p-vod-") == "p-vod-7")
        #expect(ContentSyncManager.stalkerCategoryId("7", current: "p-vod-7", playlistPrefix: "p-vod-") == nil)
    }

    @Test func `a missing category files only an unfiled row under All`() {
        #expect(ContentSyncManager.stalkerCategoryId(nil, current: nil, playlistPrefix: "p-vod-") == "p-vod-*")
        #expect(ContentSyncManager.stalkerCategoryId(nil, current: "p-vod-3", playlistPrefix: "p-vod-") == nil)
    }

    @Test func `a search hit keeps an existing title in its category`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let hit = try item(#"{"id": "42", "name": "Arrival", "cmd": "ffrt http://x/42"}"#)
        let manager = ContentSyncManager(modelContainer: container)

        var seen = Set<String>()
        _ = try await manager.upsertStalkerMovies(
            [(item: hit, categoryId: "3")], playlistPrefix: prefix, playlistId: playlistId, seenIds: &seen
        )
        _ = try await manager.upsertStalkerMovies(
            [(item: hit, categoryId: nil)], playlistPrefix: prefix, playlistId: playlistId, seenIds: &seen
        )

        let movie = try #require(try ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        #expect(movie.categoryId == "\(prefix)3")
        #expect(movie.name == "Arrival")
        #expect(movie.directURL == "ffrt http://x/42")
    }

    @Test func `an unchanged re-upsert leaves the row untouched`() async throws {
        let container = try makeTestContainer()
        let playlistId = UUID()
        let prefix = "\(playlistId.uuidString)-vod-"
        let entry: StalkerCatalogEntry = try (
            item: item(#"{"id": "42", "name": "Arrival", "cmd": "c", "rating": "7.5", "added": "2026-01-01 00:00:00"}"#),
            categoryId: "3"
        )
        let manager = ContentSyncManager(modelContainer: container)
        var seen = Set<String>()
        _ = try await manager.upsertStalkerMovies([entry], playlistPrefix: prefix, playlistId: playlistId, seenIds: &seen)

        // User state written between syncs must survive a re-walk, and a
        // re-walk of an unchanged portal writes nothing over it.
        do {
            let context = ModelContext(container)
            let movie = try #require(try context.fetch(FetchDescriptor<Movie>()).first)
            movie.isFavorite = true
            try context.save()
        }
        let imported = try await manager.upsertStalkerMovies(
            [entry], playlistPrefix: prefix, playlistId: playlistId, seenIds: &seen
        )

        #expect(imported == 1)
        let movie = try #require(try ModelContext(container).fetch(FetchDescriptor<Movie>()).first)
        #expect(movie.isFavorite)
        #expect(movie.rating == 7.5)
        #expect(movie.added == "2026-01-01 00:00:00")
    }
}

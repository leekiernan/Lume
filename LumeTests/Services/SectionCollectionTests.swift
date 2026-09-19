//
//  SectionCollectionTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SectionCollectionTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func `preview keeps lightweight tail for a later page`() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for tmdbId in 1 ... 30 {
            let movie = Movie(id: "mine-movie-\(tmdbId)", streamId: tmdbId, name: "Movie \(tmdbId)")
            movie.tmdbId = tmdbId
            context.insert(movie)
        }
        try context.save()

        let entries = (1 ... 30).map {
            HomeListEntry(tmdbId: $0, mediaType: .movie, title: "Remote \($0)")
        }
        let scope = SectionFeed.Context(
            modelContext: context,
            restriction: ContentRestriction(),
            playlistPrefix: "mine-"
        )
        let snapshot = SectionCollectionResolver.snapshot(
            entries: entries,
            mediaType: .movie,
            context: scope,
            previewLimit: 20
        )

        #expect(snapshot.preview.map(\.title) == (1 ... 20).map { "Movie \($0)" })
        #expect(snapshot.entries.count == 30)
        #expect(snapshot.nextOffset == 20)
        #expect(snapshot.hasMoreCandidates)

        let next = SectionCollectionResolver.page(
            entries: snapshot.entries,
            from: snapshot.nextOffset,
            limit: 100,
            context: scope
        )
        #expect(next.items.map(\.title) == (21 ... 30).map { "Movie \($0)" })
        #expect(next.nextOffset == 30)
        #expect(!next.hasMoreCandidates)
    }

    @Test func `normalization filters medium and deduplicates stable ids`() {
        let entries = [
            HomeListEntry(tmdbId: 1, mediaType: .movie, title: "First"),
            HomeListEntry(tmdbId: 1, mediaType: .movie, title: "Duplicate"),
            HomeListEntry(tmdbId: 1, mediaType: .series, title: "Same id, other medium"),
            HomeListEntry(tmdbId: 2, mediaType: .movie, title: "Second")
        ]

        let movies = SectionCollectionResolver.normalizedEntries(entries, mediaType: .movie)
        #expect(movies.map(\.title) == ["First", "Second"])

        let mixed = SectionCollectionResolver.normalizedEntries(entries, mediaType: nil)
        #expect(mixed.map(\.title) == ["First", "Same id, other medium", "Second"])
    }

    @Test func `catalog resolution respects playlist and hidden categories`() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let visible = Movie(id: "mine-movie-1", streamId: 1, name: "Visible", categoryId: "open")
        visible.tmdbId = 1
        let anotherPlaylist = Movie(id: "other-movie-2", streamId: 2, name: "Other", categoryId: "open")
        anotherPlaylist.tmdbId = 2
        let hidden = Movie(id: "mine-movie-3", streamId: 3, name: "Hidden", categoryId: "hidden")
        hidden.tmdbId = 3
        context.insert(visible)
        context.insert(anotherPlaylist)
        context.insert(hidden)
        try context.save()

        let entries = (1 ... 4).map {
            HomeListEntry(tmdbId: $0, mediaType: .movie, title: "Remote \($0)")
        }
        let scope = SectionFeed.Context(
            modelContext: context,
            restriction: ContentRestriction(isActive: false, hiddenCategoryIDs: ["hidden"]),
            playlistPrefix: "mine-"
        )
        let snapshot = SectionCollectionResolver.snapshot(
            entries: entries,
            mediaType: .movie,
            context: scope,
            previewLimit: 20
        )

        #expect(snapshot.preview.map(\.title) == ["Visible"])
        #expect(snapshot.nextOffset == entries.count)
        #expect(!snapshot.hasMoreCandidates)
    }
}

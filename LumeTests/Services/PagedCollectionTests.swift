//
//  PagedCollectionTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct PagedCollectionTests {
    @Test func `source cursor advances independently while duplicate titles collapse`() throws {
        let container = try makeSQLiteContainer()
        let context = ModelContext(container)
        let mine = "\(UUID().uuidString)-"

        for index in 0 ..< 250 {
            let movie = Movie(
                id: "\(mine)movie-\(String(format: "%03d", index))",
                streamId: index,
                name: index < 200 ? "A Mirror \(index)" : "B Title \(index)"
            )
            movie.isFavorite = true
            movie.tmdbId = index < 200 ? 1 : index
            context.insert(movie)
        }
        try context.save()

        let collection = PagedCollection<Movie>()
        collection.prepare(for: "favorites")
        var loads = 0
        while collection.canLoadMore, loads < 5 {
            collection.loadNextPage(
                in: context,
                pageSize: 100,
                deduplicateBy: { $0.tmdbId.map(AnyHashable.init) },
                descriptor: { offset, limit in
                    MovieCollectionQuery.pageDescriptor(
                        for: .favorites,
                        playlistPrefix: mine,
                        excludedCategoryIDs: [],
                        offset: offset,
                        limit: limit
                    )
                }
            )
            loads += 1
        }

        #expect(!collection.canLoadMore)
        #expect(collection.items.count == 51)
        #expect(Set(collection.items.compactMap(\.tmdbId)).count == 51)
    }

    private func makeSQLiteContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }
}

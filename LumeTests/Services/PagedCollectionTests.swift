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
    /// A catalog of `count` movies under one playlist prefix, ids zero-padded so
    /// sorting by id is insertion order.
    private func seed(_ count: Int, in context: ModelContext) throws -> String {
        let prefix = "\(UUID().uuidString)-"
        for index in 0 ..< count {
            context.insert(Movie(id: "\(prefix)movie-\(String(format: "%03d", index))", streamId: index, name: "Title \(index)"))
        }
        try context.save()
        return prefix
    }

    private func page(_ prefix: String) -> (Int, Int) -> FetchDescriptor<Movie> {
        { offset, limit in
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.id.starts(with: prefix) },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit
            return descriptor
        }
    }

    @Test func `pages load in order until a short page ends the results`() throws {
        let context = try ModelContext(makeSQLiteContainer())
        let prefix = try seed(250, in: context)
        let collection = PagedCollection<Movie>()
        collection.prepare(for: "all")

        collection.loadNextPage(in: context, pageSize: 100, descriptor: page(prefix))
        #expect(collection.items.count == 100)
        #expect(collection.canLoadMore)

        collection.loadNextPage(in: context, pageSize: 100, descriptor: page(prefix))
        collection.loadNextPage(in: context, pageSize: 100, descriptor: page(prefix))
        #expect(collection.items.count == 250)
        #expect(!collection.canLoadMore)
        #expect(collection.items.map(\.streamId) == Array(0 ..< 250))

        // At the end, a further request is a no-op rather than a re-fetch.
        collection.loadNextPage(in: context, pageSize: 100, descriptor: page(prefix))
        #expect(collection.items.count == 250)
    }

    @Test func `the same key keeps the loaded window and a new key resets it`() throws {
        let context = try ModelContext(makeSQLiteContainer())
        let prefix = try seed(150, in: context)
        let collection = PagedCollection<Movie>()

        collection.prepare(for: "favorites")
        collection.loadNextPage(in: context, pageSize: 100, descriptor: page(prefix))
        // Returning to the grid (same query inputs) keeps what was loaded.
        collection.prepare(for: "favorites")
        #expect(collection.items.count == 100)

        collection.prepare(for: "recent")
        #expect(collection.items.isEmpty)
        #expect(collection.canLoadMore)
    }

    @Test func `a row returned on two pages is not added twice`() throws {
        let context = try ModelContext(makeSQLiteContainer())
        let prefix = try seed(10, in: context)
        let collection = PagedCollection<Movie>()
        collection.prepare(for: "all")

        // A descriptor that ignores the offset returns the same rows each time —
        // as a page boundary does when a row moves between fetches.
        let firstFive: (Int, Int) -> FetchDescriptor<Movie> = { _, limit in page(prefix)(0, limit) }
        collection.loadNextPage(in: context, pageSize: 5, descriptor: firstFive)
        collection.loadNextPage(in: context, pageSize: 5, descriptor: firstFive)
        #expect(collection.items.count == 5)
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

//
//  LibraryCollectionPagingTests.swift
//  LumeTests
//
//  "Show All" library collections page instead of materialising the whole
//  catalog — split from BrowseQueryShapeTests.swift purely to keep that file
//  under the line-length cap.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

extension BrowseQueryShapeTests {
    /// Complete descriptors remain available for explicit reads and benchmarks,
    /// while the shipping grids request bounded windows.
    @Test func `show-all grids use consistent pages`() {
        #expect(MovieCollectionQuery.gridDescriptor(for: .favorites, playlistPrefix: prefix).fetchLimit == nil)
        #expect(MovieCollectionQuery.gridDescriptor(for: .recentlyWatched, playlistPrefix: prefix).fetchLimit == nil)
        #expect(MovieCollectionQuery.gridDescriptor(for: .recentlyAdded, playlistPrefix: prefix).fetchLimit == nil)
        #expect(SeriesCollectionQuery.gridDescriptor(for: .favorites, playlistPrefix: prefix).fetchLimit == nil)
        #expect(SeriesCollectionQuery.gridDescriptor(for: .recentlyWatched, playlistPrefix: prefix).fetchLimit == nil)
        #expect(SeriesCollectionQuery.gridDescriptor(for: .recentlyAdded, playlistPrefix: prefix).fetchLimit == nil)

        let page = MovieCollectionQuery.pageDescriptor(
            for: .recentlyAdded, playlistPrefix: prefix, excludedCategoryIDs: [], offset: 200, limit: 100
        )
        #expect(page.fetchOffset == 200)
        #expect(page.fetchLimit == 100)

        let seriesPage = SeriesCollectionQuery.pageDescriptor(
            for: .recentlyAdded, playlistPrefix: prefix, excludedCategoryIDs: [], offset: 300, limit: 50
        )
        #expect(seriesPage.fetchOffset == 300)
        #expect(seriesPage.fetchLimit == 50)
    }

    /// Restrictions belong to the query, rather than a filter applied after a
    /// page has already been selected.
    @Test func `collection pages select visible titles before applying their limit`() throws {
        let container = try makeSQLiteContainer()
        let context = ModelContext(container)
        let mine = "\(UUID().uuidString)-"
        let locked = "\(mine)locked"

        for index in 0 ..< 120 {
            let movie = Movie(
                id: "\(mine)locked-\(index)", streamId: index,
                name: "Locked \(index)", categoryId: locked
            )
            movie.lastWatchedDate = Date(timeIntervalSince1970: Double(10000 + index))
            context.insert(movie)
        }
        let visible = Movie(id: "\(mine)visible", streamId: 500, name: "Visible")
        visible.lastWatchedDate = .distantPast
        context.insert(visible)
        try context.save()

        let page = MovieCollectionQuery.pageDescriptor(
            for: .recentlyWatched, playlistPrefix: mine,
            excludedCategoryIDs: [locked], offset: 0, limit: 100
        )
        #expect(try context.fetch(page).map(\.id) == [visible.id])
    }

    /// Equal watch timestamps are common after imports; stable final keys keep
    /// titles from moving between offsets as pages load.
    @Test func `collection page ordering is stable across equal timestamps`() throws {
        let container = try makeSQLiteContainer()
        let context = ModelContext(container)
        let mine = "\(UUID().uuidString)-"
        let watchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0 ..< 205 {
            let movie = Movie(
                id: "\(mine)movie-\(String(format: "%03d", index))",
                streamId: index,
                name: "Movie \(index % 7)"
            )
            movie.lastWatchedDate = watchedAt
            context.insert(movie)
        }
        try context.save()

        let pages = try stride(from: 0, through: 200, by: 100).flatMap { offset in
            try context.fetch(MovieCollectionQuery.pageDescriptor(
                for: .recentlyWatched, playlistPrefix: mine,
                excludedCategoryIDs: [], offset: offset, limit: 100
            ))
        }
        #expect(pages.count == 205)
        #expect(Set(pages.map(\.id)).count == 205)
        let complete = try context.fetch(MovieCollectionQuery.gridDescriptor(
            for: .recentlyWatched, playlistPrefix: mine
        ))
        #expect(pages.map(\.id) == complete.map(\.id))
    }
}

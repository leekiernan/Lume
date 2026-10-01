//
//  CollectionSortShapeTests.swift
//  LumeTests
//
//  The sort contract behind the Recently Added rails, beside
//  BrowseQueryShapeTests (at its length limit). A sort that changes no
//  visible row can still cost the index — this pins the one that doesn't.
//

@testable import Lume
import SwiftData
import Testing

struct CollectionSortShapeTests {
    private let prefix = "playlist-"

    /// Newest first, then the unique id — nothing between. A third sort key
    /// tips SQLite from the `added` index to `SCAN ZMOVIE` plus a sort of the
    /// whole table (0.6 → 10.5 ms per fetch, `BrowseQueryBenchmarks`).
    @Test func `recently added sorts on exactly two keys`() {
        let counts = [
            MovieCollectionQuery.rowDescriptor(for: .recentlyAdded, playlistPrefix: prefix, excludedCategoryIDs: []).sortBy.count,
            MovieCollectionQuery.pageDescriptor(
                for: .recentlyAdded, playlistPrefix: prefix, excludedCategoryIDs: [], offset: 0, limit: 50
            ).sortBy.count,
            SeriesCollectionQuery.rowDescriptor(for: .recentlyAdded, playlistPrefix: prefix, excludedCategoryIDs: []).sortBy.count,
            SeriesCollectionQuery.pageDescriptor(
                for: .recentlyAdded, playlistPrefix: prefix, excludedCategoryIDs: [], offset: 0, limit: 50
            ).sortBy.count
        ]
        #expect(counts == [2, 2, 2, 2])
    }
}

//
//  LibraryCollectionQuery.swift
//  Lume
//
//  The fetches behind the Movies and Series collection rows and their Show
//  All grids. Split out of LibraryCollectionRows.swift (the 600-line cap).
//

import Foundation
import SwiftData

/// Internal, not fileprivate, so the tests and benchmarks can build these
/// descriptors and assert their shape — the `fetchLimit`, the playlist scope and
/// the lexical `added` comparator are performance contracts a well-meaning
/// refactor can undo without changing a single visible row. Same reasoning as
/// the search predicates in `SearchFetching.swift`.
enum MovieCollectionQuery {
    /// The fetch behind a preview row — always bounded, see
    /// `collectionRowFetchLimit`.
    static func rowDescriptor(
        for kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<Movie> {
        var descriptor = base(for: kind, playlistPrefix: playlistPrefix, excludedCategoryIDs: excludedCategoryIDs)
        descriptor.fetchLimit = collectionRowFetchLimit
        return descriptor
    }

    /// Unbounded descriptor retained for benchmarks and callers that explicitly
    /// need a complete result. The shipping full grid uses `pageDescriptor`.
    static func gridDescriptor(for kind: LibraryCollection.Kind, playlistPrefix: String) -> FetchDescriptor<Movie> {
        base(for: kind, playlistPrefix: playlistPrefix)
    }

    static func pageDescriptor(
        for kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>,
        offset: Int,
        limit: Int
    ) -> FetchDescriptor<Movie> {
        var descriptor = base(
            for: kind,
            playlistPrefix: playlistPrefix,
            excludedCategoryIDs: excludedCategoryIDs
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    private static func base(
        for kind: LibraryCollection.Kind,
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String> = []
    ) -> FetchDescriptor<Movie> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        // Watched movies split by whether they're finished (`WatchCompletion`).
        let finished = kind == .recentlyWatched
        return switch kind {
        case .continueWatching, .recentlyWatched:
            FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.lastWatchedDate != nil
                        && $0.isWatched == finished
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [
                    SortDescriptor(\.lastWatchedDate, order: .reverse),
                    SortDescriptor(\.name),
                    SortDescriptor(\.id)
                ]
            )
        case .favorites:
            FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.isFavorite
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                // The user's arrangement from Content Management › Favorites,
                // as on Home. Never-reordered favorites (nil) sort by name.
                sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name), SortDescriptor(\.id)]
            )
        case .recentlyAdded:
            // `comparator: .lexical`, not the `.localizedStandard` default:
            // `added` is a Unix timestamp string, and the localized comparator
            // emits `COLLATE NSCollateFinderlike`, which the `#Index` on
            // `Movie.added` cannot serve. 222.4 ms → 92.6 ms on a 179k-title
            // catalog, and that one query was 46% of a cold launch's SQL.
            FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.added != nil
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [
                    SortDescriptor(\.added, comparator: .lexical, order: .reverse),
                    SortDescriptor(\.num),
                    SortDescriptor(\.id)
                ]
            )
        }
    }
}

/// Internal for the same reason as `MovieCollectionQuery`.
enum SeriesCollectionQuery {
    /// The fetch behind a preview row — always bounded, see
    /// `collectionRowFetchLimit`.
    static func rowDescriptor(
        for kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<Series> {
        var descriptor = base(for: kind, playlistPrefix: playlistPrefix, excludedCategoryIDs: excludedCategoryIDs)
        descriptor.fetchLimit = collectionRowFetchLimit
        return descriptor
    }

    /// Unbounded descriptor retained for benchmarks and explicit complete reads.
    static func gridDescriptor(for kind: LibraryCollection.Kind, playlistPrefix: String) -> FetchDescriptor<Series> {
        base(for: kind, playlistPrefix: playlistPrefix)
    }

    static func pageDescriptor(
        for kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>,
        offset: Int,
        limit: Int
    ) -> FetchDescriptor<Series> {
        var descriptor = base(
            for: kind,
            playlistPrefix: playlistPrefix,
            excludedCategoryIDs: excludedCategoryIDs
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    private static func base(
        for kind: LibraryCollection.Kind,
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String> = []
    ) -> FetchDescriptor<Series> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        return switch kind {
        // One query for both: whether a series is finished is known from its
        // episodes, not a column — see `ContinueWatchingLoader`.
        case .continueWatching, .recentlyWatched:
            FetchDescriptor<Series>(
                predicate: #Predicate {
                    $0.lastWatchedDate != nil
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [
                    SortDescriptor(\.lastWatchedDate, order: .reverse),
                    SortDescriptor(\.name),
                    SortDescriptor(\.id)
                ]
            )
        case .favorites:
            FetchDescriptor<Series>(
                predicate: #Predicate {
                    $0.isFavorite
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                // The user's arrangement from Content Management › Favorites,
                // as on Home. Never-reordered favorites (nil) sort by name.
                sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name), SortDescriptor(\.id)]
            )
        case .recentlyAdded:
            // `comparator: .lexical` for the same reason as the movie side:
            // `lastModified` is a Unix timestamp string, and the default
            // localized comparator forfeits the `#Index` to NSCollateFinderlike.
            FetchDescriptor<Series>(
                predicate: #Predicate {
                    $0.lastModified != nil
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [
                    SortDescriptor(\.lastModified, comparator: .lexical, order: .reverse),
                    SortDescriptor(\.num),
                    SortDescriptor(\.id)
                ]
            )
        }
    }
}

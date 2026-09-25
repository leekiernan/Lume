//
//  LibraryCollectionRowQueryTests.swift
//  LumeTests
//
//  The Movies/Series Recently Watched and Favorites preview rows select their
//  titles in SQL — playlist, hidden categories and favorite order all precede
//  the `fetchLimit` — the same way Home's rows do (`HomeQuery`). The descriptor
//  shape itself is covered by `BrowseQueryShapeTests`.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LibraryCollectionRowQueryTests {
    private let mine = "\(UUID().uuidString)-"

    /// The preview rows used to take the newest 200 rows and only then drop
    /// hidden categories in Swift, so enough hidden titles could empty the row.
    /// Like Home, the restriction now runs before the limit.
    @Test func `collection rows select visible titles before applying their limit`() throws {
        try OnDiskCatalogStore.withContext { context in
            let locked = "\(mine)locked"
            for index in 0 ..< collectionPreviewLimit * 2 {
                let watchedAt = Date(timeIntervalSince1970: Double(10000 + index))
                let movie = Movie(
                    id: "\(mine)movie-locked-\(index)", streamId: index,
                    name: "Locked \(index)", categoryId: locked
                )
                mark(movie, watchedAt: watchedAt)
                context.insert(movie)
                let series = Series(
                    id: "\(mine)series-locked-\(index)", seriesId: index,
                    name: "Locked \(index)", categoryId: locked
                )
                mark(series, watchedAt: watchedAt)
                context.insert(series)
            }
            let visibleMovie = Movie(id: "\(mine)movie-visible", streamId: 500, name: "Visible")
            mark(visibleMovie, watchedAt: .distantPast)
            context.insert(visibleMovie)
            let visibleSeries = Series(id: "\(mine)series-visible", seriesId: 500, name: "Visible")
            mark(visibleSeries, watchedAt: .distantPast)
            context.insert(visibleSeries)
            try context.save()

            for kind in [LibraryCollection.Kind.recentlyWatched, .favorites] {
                let movies = try context.fetch(MovieCollectionQuery.rowDescriptor(
                    for: kind, playlistPrefix: mine, excludedCategoryIDs: [locked]
                ))
                let series = try context.fetch(SeriesCollectionQuery.rowDescriptor(
                    for: kind, playlistPrefix: mine, excludedCategoryIDs: [locked]
                ))
                #expect(movies.map(\.id) == [visibleMovie.id], "\(kind)")
                #expect(series.map(\.id) == [visibleSeries.id], "\(kind)")
            }
        }
    }

    /// Favorites follow the arrangement from Content Management › Favorites, as
    /// Home's rail does, and fall back to name for never-reordered titles.
    @Test func `favorite rows honour the user's favorite order`() throws {
        try OnDiskCatalogStore.withContext { context in
            let arranged = [("Zulu", 0), ("Alpha", 1), ("Mike", 2)]
            for (index, (name, order)) in arranged.enumerated() {
                let movie = Movie(id: "\(mine)movie-\(index)", streamId: index, name: name)
                movie.isFavorite = true
                movie.favoriteOrder = order
                context.insert(movie)
                let series = Series(id: "\(mine)series-\(index)", seriesId: index, name: name)
                series.isFavorite = true
                series.favoriteOrder = order
                context.insert(series)
            }
            try context.save()

            let movies = try context.fetch(MovieCollectionQuery.rowDescriptor(
                for: .favorites, playlistPrefix: mine, excludedCategoryIDs: []
            ))
            let series = try context.fetch(SeriesCollectionQuery.rowDescriptor(
                for: .favorites, playlistPrefix: mine, excludedCategoryIDs: []
            ))
            #expect(movies.map(\.name) == ["Zulu", "Alpha", "Mike"])
            #expect(series.map(\.name) == ["Zulu", "Alpha", "Mike"])

            for movie in movies {
                movie.favoriteOrder = nil
            }
            try context.save()
            let byName = try context.fetch(MovieCollectionQuery.rowDescriptor(
                for: .favorites, playlistPrefix: mine, excludedCategoryIDs: []
            ))
            #expect(byName.map(\.name) == ["Alpha", "Mike", "Zulu"])
        }
    }

    // MARK: - Helpers

    private func mark(_ movie: Movie, watchedAt date: Date) {
        movie.isFavorite = true
        movie.lastWatchedDate = date
    }

    private func mark(_ series: Series, watchedAt date: Date) {
        series.isFavorite = true
        series.lastWatchedDate = date
    }
}

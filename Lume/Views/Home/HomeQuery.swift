//
//  HomeQuery.swift
//  Lume
//
//  Bounded local feeds used by Home. Playlist and visibility selection belongs
//  in these descriptors so it happens before SwiftData applies each limit.
//

import Foundation
import SwiftData

/// Internal so the on-disk query tests can exercise the real descriptors.
nonisolated enum HomeQuery {
    static let watchedLimit = 20
    static let favoritesLimit = 30

    static func watchedMovies(
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<Movie> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { movie in
                movie.lastWatchedDate != nil
                    && movie.id.starts(with: prefix)
                    && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
            },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        descriptor.fetchLimit = watchedLimit
        return descriptor
    }

    static func watchedSeries(
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<Series> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate { series in
                series.lastWatchedDate != nil
                    && series.id.starts(with: prefix)
                    && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
            },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        descriptor.fetchLimit = watchedLimit
        return descriptor
    }

    static func watchedStreams(
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<LiveStream> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        var descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { stream in
                stream.lastWatchedDate != nil
                    && stream.isHidden == false
                    && stream.id.starts(with: prefix)
                    && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
            },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        descriptor.fetchLimit = watchedLimit
        return descriptor
    }

    static func favoriteMovies(
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<Movie> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { movie in
                movie.isFavorite
                    && movie.id.starts(with: prefix)
                    && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
            },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        descriptor.fetchLimit = favoritesLimit
        return descriptor
    }

    static func favoriteSeries(
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<Series> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        var descriptor = FetchDescriptor<Series>(
            predicate: #Predicate { series in
                series.isFavorite
                    && series.id.starts(with: prefix)
                    && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
            },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        descriptor.fetchLimit = favoritesLimit
        return descriptor
    }

    static func favoriteStreams(
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<LiveStream> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        var descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { stream in
                stream.isFavorite
                    && stream.isHidden == false
                    && stream.id.starts(with: prefix)
                    && (!filtersCategories || stream.categoryId == nil || !excluded.contains(stream.categoryId))
            },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        descriptor.fetchLimit = favoritesLimit
        return descriptor
    }
}

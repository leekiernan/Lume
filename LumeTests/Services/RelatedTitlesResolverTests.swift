//
//  RelatedTitlesResolverTests.swift
//  LumeTests
//
//  The detail screens' "You May Also Like" / collection rails. Runs on an
//  on-disk store: the batched `contains` + `starts(with:)` predicate must
//  render as SQL, which an in-memory store never exercises.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct RelatedTitlesResolverTests {
    private let own = "11111111-1111-1111-1111-111111111111"
    private let other = "22222222-2222-2222-2222-222222222222"

    @discardableResult
    private func movie(_ id: String, tmdb: Int, in context: ModelContext) -> Movie {
        let movie = Movie(id: id, streamId: tmdb, name: id)
        movie.tmdbId = tmdb
        context.insert(movie)
        return movie
    }

    @discardableResult
    private func series(_ id: String, tmdb: Int, in context: ModelContext) -> Series {
        let series = Series(id: id, seriesId: tmdb, name: id)
        series.tmdbId = tmdb
        context.insert(series)
        return series
    }

    @Test func `playlist prefix is the uuid plus separator`() {
        #expect(RelatedTitlesResolver.playlistPrefix(of: "\(own)-movie-42") == "\(own)-")
        #expect(RelatedTitlesResolver.playlistPrefix(of: "not-a-playlist-id").isEmpty)
    }

    @Test func `movie similar keeps TMDB order, prefers movies and scopes to the playlist`() throws {
        try OnDiskCatalogStore.withContext { context in
            let subject = movie("\(own)-movie-1", tmdb: 1, in: context)
            subject.similarTitleIds = [30, 10, 20, 1, 40, 50]
            let ten = movie("\(own)-movie-10", tmdb: 10, in: context)
            series("\(own)-series-10", tmdb: 10, in: context) // loses to the movie
            let twenty = series("\(own)-series-20", tmdb: 20, in: context) // series fallback
            let thirty = movie("\(own)-movie-30", tmdb: 30, in: context)
            movie("\(other)-movie-40", tmdb: 40, in: context) // another playlist
            try context.save()

            let resolved = RelatedTitlesResolver.similar(to: subject, in: context)
            #expect(resolved == [.movie(thirty), .movie(ten), .series(twenty)])
        }
    }

    @Test func `series similar prefers series and excludes itself`() throws {
        try OnDiskCatalogStore.withContext { context in
            let subject = series("\(own)-series-1", tmdb: 1, in: context)
            subject.similarTitleIds = [1, 10]
            movie("\(own)-movie-10", tmdb: 10, in: context)
            let preferred = series("\(own)-series-10", tmdb: 10, in: context)
            try context.save()

            let resolved = RelatedTitlesResolver.similar(to: subject, in: context)
            #expect(resolved == [.series(preferred)])
        }
    }

    @Test func `similar is capped for the rail`() throws {
        try OnDiskCatalogStore.withContext { context in
            let subject = movie("\(own)-movie-0", tmdb: 1000, in: context)
            let ids = Array(1 ... 20)
            subject.similarTitleIds = ids
            for id in ids {
                movie("\(own)-movie-\(id)", tmdb: id, in: context)
            }
            try context.save()

            let resolved = RelatedTitlesResolver.similar(to: subject, in: context)
            #expect(resolved.count == RelatedTitlesResolver.similarLimit)
        }
    }

    @Test func `collection parts are movies only, in part order, without the subject`() throws {
        try OnDiskCatalogStore.withContext { context in
            let subject = movie("\(own)-movie-2", tmdb: 2, in: context)
            let first = movie("\(own)-movie-1", tmdb: 1, in: context)
            let third = movie("\(own)-movie-3", tmdb: 3, in: context)
            series("\(own)-series-4", tmdb: 4, in: context)
            movie("\(other)-movie-5", tmdb: 5, in: context)
            try context.save()

            let parts = RelatedTitlesResolver.collectionParts([1, 2, 3, 4, 5], of: subject, in: context)
            #expect(parts == [.movie(first), .movie(third)])
        }
    }

    @Test func `freshness window`() {
        let now = Date()
        #expect(TMDBFreshness.isFresh(nil, now: now) == false)
        #expect(TMDBFreshness.isFresh(now.addingTimeInterval(-3600), now: now))
        #expect(TMDBFreshness.isFresh(now.addingTimeInterval(-TMDBFreshness.window - 1), now: now) == false)
    }
}

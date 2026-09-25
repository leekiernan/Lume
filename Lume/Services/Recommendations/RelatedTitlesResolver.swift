//
//  RelatedTitlesResolver.swift
//  Lume
//
//  Maps TMDB ids (a title's "similar" list, a movie collection's parts) back
//  to catalog rows in the same playlist, for the detail screens' "You May Also
//  Like" and collection rails on every platform.
//
//  One fetch per model type: `ids.contains(tmdbId) && id.starts(with: prefix)`
//  scopes by playlist in SQL (a range seek on the unique `id` index) instead of
//  fetching every playlist's copy of each id and filtering in Swift.
//

import Foundation
import SwiftData

enum RelatedTitlesResolver {
    /// Rails cap "You May Also Like" at this many titles.
    static let similarLimit = 12

    /// The `"<playlistUUID>-"` prefix every catalog id starts with. Empty — an
    /// unscoped match — when `id` doesn't carry a playlist UUID.
    static func playlistPrefix(of id: String) -> String {
        let head = String(id.prefix(36))
        guard UUID(uuidString: head) != nil else { return "" }
        return head + "-"
    }

    /// Titles similar to `movie`: a movie match for each TMDB id, else a series
    /// with it, in TMDB's order.
    static func similar(to movie: Movie, in context: ModelContext) -> [HomeMediaItem] {
        let items = resolve(
            movie.similarTitleIds,
            prefix: playlistPrefix(of: movie.id),
            excluding: movie.id,
            preferring: .movies,
            in: context
        )
        return Array(items.prefix(similarLimit))
    }

    /// Titles similar to `series`: a series match for each TMDB id, else a
    /// movie with it, in TMDB's order.
    static func similar(to series: Series, in context: ModelContext) -> [HomeMediaItem] {
        let items = resolve(
            series.similarTitleIds,
            prefix: playlistPrefix(of: series.id),
            excluding: series.id,
            preferring: .series,
            in: context
        )
        return Array(items.prefix(similarLimit))
    }

    /// The other parts of `movie`'s collection present in its playlist, in the
    /// order of `partIDs`. Movies only.
    static func collectionParts(_ partIDs: [Int], of movie: Movie, in context: ModelContext) -> [HomeMediaItem] {
        resolve(
            partIDs,
            prefix: playlistPrefix(of: movie.id),
            excluding: movie.id,
            preferring: .moviesOnly,
            in: context
        )
    }

    enum Preference {
        case movies
        case series
        case moviesOnly
    }

    /// Resolves each TMDB id to at most one item, preferring the kind named by
    /// `preference`, in the order of `ids`. `excluding` drops the title the
    /// screen is showing. Ties within a playlist (two rows with one TMDB id)
    /// resolve to the lowest id, so the rail is stable across renders.
    static func resolve(
        _ ids: [Int],
        prefix: String,
        excluding ownID: String,
        preferring preference: Preference,
        in context: ModelContext
    ) -> [HomeMediaItem] {
        guard !ids.isEmpty else { return [] }
        // `Set<Int?>`: `contains` over the optional column compiles to SQL `IN`;
        // unwrapping (`$0.tmdbId ?? -1`) renders a ternary SQLite can't take.
        let wanted = Set(ids.map(Int?.some))

        var movies: [Int: Movie] = [:]
        let movieDescriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { wanted.contains($0.tmdbId) && $0.id.starts(with: prefix) },
            sortBy: [SortDescriptor(\.id)]
        )
        let movieRows = (try? context.fetch(movieDescriptor)) ?? []
        for movie in movieRows where movie.id != ownID {
            if let tmdbId = movie.tmdbId, movies[tmdbId] == nil { movies[tmdbId] = movie }
        }

        var series: [Int: Series] = [:]
        if preference != .moviesOnly {
            let seriesDescriptor = FetchDescriptor<Series>(
                predicate: #Predicate { wanted.contains($0.tmdbId) && $0.id.starts(with: prefix) },
                sortBy: [SortDescriptor(\.id)]
            )
            let seriesRows = (try? context.fetch(seriesDescriptor)) ?? []
            for show in seriesRows where show.id != ownID {
                if let tmdbId = show.tmdbId, series[tmdbId] == nil { series[tmdbId] = show }
            }
        }

        var seen = Set<Int>()
        return ids.compactMap { tmdbId in
            guard seen.insert(tmdbId).inserted else { return nil }
            let movie = movies[tmdbId].map(HomeMediaItem.movie)
            let show = series[tmdbId].map(HomeMediaItem.series)
            switch preference {
            case .movies: return movie ?? show
            case .series: return show ?? movie
            case .moviesOnly: return movie
            }
        }
    }
}

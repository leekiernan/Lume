//
//  HeroItem.swift
//  Lume
//
//  The model backing the home-screen hero carousel: a Movie or Series the user
//  owns, paired with the TMDB-sourced wide artwork and copy that make it look
//  cinematic. The carousel view itself lives in `HomeHeroCarousel.swift`.
//

import Foundation

/// One featured item in the hero carousel: a Movie or Series the user owns,
/// plus the TMDB-sourced wide artwork and copy that make it look cinematic.
enum HeroItem: Identifiable, Hashable {
    case movie(Movie, backdropURL: URL?, overview: String)
    case series(Series, backdropURL: URL?, overview: String)

    var id: String {
        switch self {
        case let .movie(movie, _, _): "movie-\(movie.id)"
        case let .series(series, _, _): "series-\(series.id)"
        }
    }

    var title: String {
        switch self {
        case let .movie(movie, _, _): movie.name
        case let .series(series, _, _): series.name
        }
    }

    var overview: String {
        switch self {
        case let .movie(_, _, overview): overview
        case let .series(_, _, overview): overview
        }
    }

    var imageURL: URL? {
        switch self {
        case let .movie(movie, backdrop, _):
            backdrop ?? URL(string: movie.streamIcon ?? "")
        case let .series(series, backdrop, _):
            backdrop ?? URL(string: series.cover ?? "")
        }
    }

    /// The title's wordmark logo, shown in place of the text title when the
    /// title has been enriched from TMDB and a logo is available.
    var logoURL: URL? {
        switch self {
        case let .movie(movie, _, _): TMDBClient.logoURL(movie.logoPath)
        case let .series(series, _, _): TMDBClient.logoURL(series.logoPath)
        }
    }

    /// Whether this hero has genuine wide artwork rather than falling back to
    /// portrait cover art. A poster blown up to fill the hero's letterbox reads
    /// as a stretched crop, so a title without a backdrop is skipped instead.
    var hasWideArtwork: Bool {
        switch self {
        case let .movie(_, backdrop, _): backdrop != nil
        case let .series(_, backdrop, _): backdrop != nil
        }
    }

    var movie: Movie? {
        if case let .movie(movie, _, _) = self { return movie }
        return nil
    }

    var series: Series? {
        if case let .series(series, _, _) = self { return series }
        return nil
    }
}

extension HeroItem {
    /// Builds a hero from a row item, using the wide artwork and copy TMDB
    /// enrichment stored on the catalog model. That is what lets a promoted
    /// custom section look like the trending hero rather than a stretched
    /// poster. Live channels have no hero treatment, so they yield nil.
    init?(item: HomeMediaItem) {
        switch item {
        case let .movie(movie):
            self = .movie(
                movie,
                backdropURL: TMDBClient.backdropURL(movie.backdropPath),
                overview: movie.plot ?? ""
            )
        case let .series(series):
            self = .series(
                series,
                backdropURL: TMDBClient.backdropURL(series.backdropPath),
                overview: series.plot ?? ""
            )
        case .live:
            return nil
        }
    }
}

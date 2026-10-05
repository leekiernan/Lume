//
//  HeroItem.swift
//  Lume
//
//  The model backing the home-screen hero carousel: a Movie or Series the user
//  owns, paired with TMDB backdrop/poster artwork and copy that make it look
//  cinematic. The carousel view itself lives in `HomeHeroCarousel.swift`.
//

import Foundation

/// One featured item in the hero carousel: a Movie or Series the user owns,
/// plus TMDB artwork: backdrops for wide surfaces, posters for narrow heroes.
enum HeroItem: Identifiable, Hashable {
    case movie(Movie, backdropURL: URL?, logoURL: URL?, overview: String, posterURL: URL? = nil)
    case series(Series, backdropURL: URL?, logoURL: URL?, overview: String, posterURL: URL? = nil)

    var id: String {
        switch self {
        case let .movie(movie, _, _, _, _): "movie-\(movie.id)"
        case let .series(series, _, _, _, _): "series-\(series.id)"
        }
    }

    var title: String {
        switch self {
        case let .movie(movie, _, _, _, _): movie.name
        case let .series(series, _, _, _, _): series.name
        }
    }

    var overview: String {
        switch self {
        case let .movie(_, _, _, overview, _): overview
        case let .series(_, _, _, overview, _): overview
        }
    }

    var imageURL: URL? {
        switch self {
        case let .movie(movie, backdrop, _, _, _):
            backdrop ?? URL(string: movie.streamIcon ?? "")
        case let .series(series, backdrop, _, _, _):
            backdrop ?? URL(string: series.cover ?? "")
        }
    }

    var posterURL: URL? {
        switch self {
        case let .movie(_, _, _, _, poster), let .series(_, _, _, _, poster): poster
        }
    }

    /// The title's wordmark logo, shown in place of the text title when the
    /// title has been enriched from TMDB and a logo is available.
    var logoURL: URL? {
        switch self {
        case let .movie(_, _, logo, _, _): logo
        case let .series(_, _, logo, _, _): logo
        }
    }

    /// Whether this hero has genuine wide artwork rather than falling back to
    /// portrait cover art. Wide surfaces must not blow a poster up to fill a
    /// letterbox; narrow surfaces select `posterURL` separately.
    var hasWideArtwork: Bool {
        switch self {
        case let .movie(_, backdrop, _, _, _): backdrop != nil
        case let .series(_, backdrop, _, _, _): backdrop != nil
        }
    }

    var movie: Movie? {
        if case let .movie(movie, _, _, _, _) = self { return movie }
        return nil
    }

    var series: Series? {
        if case let .series(series, _, _, _, _) = self { return series }
        return nil
    }
}

extension HeroItem {
    /// Builds a hero from a row item, using the wide artwork and copy TMDB
    /// enrichment stored on the catalog model. That is what lets a promoted
    /// custom section look like the trending hero rather than a stretched
    /// poster. Live channels have no hero treatment, so they yield nil.
    init?(
        item: HomeMediaItem,
        backdropPath: String? = nil,
        posterPath: String? = nil,
        logoPath: String? = nil,
        overview: String? = nil
    ) {
        switch item {
        case let .movie(movie):
            self = .movie(
                movie,
                backdropURL: TMDBClient.backdropURL(backdropPath ?? movie.backdropPath),
                logoURL: TMDBClient.logoURL(logoPath ?? movie.logoPath),
                overview: overview ?? movie.plot ?? "",
                posterURL: TMDBClient.posterURL(posterPath ?? movie.posterPath, size: "original")
            )
        case let .series(series):
            self = .series(
                series,
                backdropURL: TMDBClient.backdropURL(backdropPath ?? series.backdropPath),
                logoURL: TMDBClient.logoURL(logoPath ?? series.logoPath),
                overview: overview ?? series.plot ?? "",
                posterURL: TMDBClient.posterURL(posterPath ?? series.posterPath, size: "original")
            )
        case .live:
            return nil
        }
    }
}

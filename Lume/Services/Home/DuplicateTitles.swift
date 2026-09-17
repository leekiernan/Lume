//
//  DuplicateTitles.swift
//  Lume
//
//  Providers list the same film once per stream — one entry per quality tier,
//  language or mirror — so a catalog holds several rows for one title. Watch two
//  of them and Recently Watched shows the same poster twice; favourite two and
//  Favorites does the same.
//
//  This collapses those to one row per title on the browse rails, keeping the
//  first of each group. The rails are already ordered by what matters (most
//  recently watched, favourite order), so the first is the right representative.
//
//  Deliberately narrow. The full treatment — one tile per title everywhere, with
//  a stream picker behind it — is bilipp/Lume#225, and it groups on the same
//  identity as `OtherSources`: the TMDB id. Matching that here means the two
//  agree about what "the same title" means when the larger change lands.
//

import Foundation

/// A catalog title that can be matched against its other copies.
protocol DuplicableTitle {
    /// Nil until the title has been matched to TMDB. Unmatched rows are always
    /// kept: without an id there is nothing to group them by, and dropping them
    /// would silently hide content.
    var tmdbId: Int? { get }
    /// Namespaces the id. TMDB numbers movies and series separately, so movie
    /// 238 and series 238 are unrelated titles and must not collapse together.
    static var duplicateNamespace: String { get }
}

extension Movie: DuplicableTitle {
    static var duplicateNamespace: String {
        "movie"
    }
}

extension Series: DuplicableTitle {
    static var duplicateNamespace: String {
        "series"
    }
}

extension Sequence where Element: DuplicableTitle {
    /// One row per title, in the order they arrived. A no-op for a catalog
    /// without duplicates, which is the common case.
    func deduplicatedByTitle() -> [Element] {
        var seen = Set<Int>()
        return filter { item in
            guard let tmdbId = item.tmdbId else { return true }
            return seen.insert(tmdbId).inserted
        }
    }
}

extension Sequence<HomeMediaItem> {
    /// The mixed-media variant, for rails that carry movies, series and channels
    /// together. Channels are never grouped — they have no TMDB identity, and
    /// two channels showing the same film are genuinely two channels.
    func deduplicatedByTitle() -> [HomeMediaItem] {
        var seen = Set<String>()
        return filter { item in
            guard let key = item.duplicateKey else { return true }
            return seen.insert(key).inserted
        }
    }
}

private extension HomeMediaItem {
    /// Namespaced so a movie and a series sharing a TMDB number stay distinct.
    var duplicateKey: String? {
        switch self {
        case let .movie(movie):
            movie.tmdbId.map { "\(Movie.duplicateNamespace)-\($0)" }
        case let .series(series):
            series.tmdbId.map { "\(Series.duplicateNamespace)-\($0)" }
        case .live:
            nil
        }
    }
}

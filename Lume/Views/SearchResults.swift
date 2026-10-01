//
//  SearchResults.swift
//  Lume
//
//  What a settled search shows, the filters on offer and the words around
//  them — all of which follow the areas the viewer has switched on: a
//  disabled area is neither searched, offered as a filter, nor named.
//

import SwiftUI

/// A settled search, by section.
struct SearchResults {
    var movies: [Movie] = []
    var series: [Series] = []
    /// Watchable now: channels named for the query, then channels airing a
    /// matching programme.
    var nowPlaying: [LiveStream] = []
    /// Matching programmes still to come, soonest first. Nothing already aired.
    var upcoming: [UpcomingProgramme] = []

    var isEmpty: Bool {
        movies.isEmpty && series.isEmpty && nowPlaying.isEmpty && upcoming.isEmpty
    }
}

/// A matching programme still to come, and the channel it airs on.
struct UpcomingProgramme: Identifiable {
    let stream: LiveStream
    let slot: EPGSlot

    var id: String {
        "\(stream.id)|\(slot.start.timeIntervalSince1970)"
    }
}

/// A results section's "Show All", as a navigation value.
enum SearchSection: Hashable {
    case movies
    case series
    case nowPlaying
    case upcoming
}

enum ContentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case movies = "Movies"
    case series = "Series"
    case liveTV = "Live TV"

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }

    /// The area a filter narrows to; nil for All.
    var area: AppArea? {
        switch self {
        case .all: nil
        case .movies: .movies
        case .series: .series
        case .liveTV: .liveTV
        }
    }

    /// The searchable areas, in filter order.
    static func searchableAreas(disabledRaw: String) -> [AppArea] {
        allCases.compactMap(\.area).filter { AppAreaSettings.isEnabled($0, disabledRaw: disabledRaw) }
    }

    /// The filters on offer: All, then each enabled area — or none at all when
    /// only one area is searchable, where a filter would have nothing to narrow.
    static func available(disabledRaw: String) -> [ContentFilter] {
        let areas = searchableAreas(disabledRaw: disabledRaw)
        guard areas.count > 1 else { return [] }
        return [.all] + allCases.filter { $0.area.map(areas.contains) == true }
    }
}

/// The words around search, naming only the areas that are switched on.
nonisolated enum SearchPrompt {
    /// Under the empty state: "Search for movies, series, or live TV channels".
    static func description(for areas: [AppArea]) -> String {
        if areas.count == 3 {
            // Every area: the long-standing sentence, translated as a whole.
            return String(localized: "Search for movies, series, or live TV channels")
        }
        let names = areas.map(noun)
        return String(localized: "Search for \(names.formatted(.list(type: .or)))",
                      comment: "The search screen's hint. The argument lists what can be searched, e.g. \"movies or series\".")
    }

    /// In the search field: "Movies, Series, Live TV…".
    static func field(for areas: [AppArea]) -> String {
        if areas.count == 3 { return String(localized: "Movies, Series, Live TV...") }
        let names = areas.map { area in
            switch area {
            case .movies: String(localized: "Movies")
            case .series: String(localized: "Series")
            default: String(localized: "Live TV")
            }
        }
        return names.joined(separator: ", ") + "…"
    }

    /// An area as it reads inside "Search for …".
    private static func noun(_ area: AppArea) -> String {
        switch area {
        case .movies:
            String(localized: "movies", comment: "Inside \"Search for %@\": what can be searched, in the case that sentence needs.")
        case .series:
            String(localized: "series", comment: "Inside \"Search for %@\": what can be searched, in the case that sentence needs.")
        default:
            String(localized: "live TV channels", comment: "Inside \"Search for %@\": what can be searched, in the case that sentence needs.")
        }
    }
}

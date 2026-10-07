import Foundation

/// A list title keyed by TMDB ID; ordered by the source list, not the catalog.
nonisolated struct HomeListEntry: Hashable {
    enum MediaType: Hashable {
        case movie
        case series
    }

    let tmdbId: Int
    let mediaType: MediaType
    /// Used for diagnostics/editor previews; VOD rows display the catalog title.
    let title: String
}

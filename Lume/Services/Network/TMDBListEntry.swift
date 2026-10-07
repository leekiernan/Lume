import Foundation

/// Metadata supplied by the list response itself; no per-title enrichment.
nonisolated struct TMDBListEntry: Hashable {
    let id: Int
    let mediaType: HomeListEntry.MediaType
    let title: String
    var originalTitle: String?
    var backdropPath: String?
    var posterPath: String?
    var overview: String?
    var releaseYear: String?
}

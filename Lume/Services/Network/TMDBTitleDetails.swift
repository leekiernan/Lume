import Foundation

/// Normalized TMDB detail payload shared by device and proxy delivery. Empty
/// fields retain the existing fill-missing application policy.
nonisolated struct TMDBTitleDetails {
    /// Validated complete proxy payload only, never catalogue availability.
    var proxyReceipt: LumeMetadataReceipt?
    var posterPath: String?
    var backdropPath: String?
    var tagline: String?
    var overview: String?
    var voteAverage: Double?
    var runtimeMinutes: Int?
    var genreNames: [String]
    var contentRating: String?
    var cast: [TMDBCastMember]
    var similarIDs: [Int]
    /// YouTube videos (trailers, teasers, clips) in display order.
    var videos: [TitleVideo]
    /// Relative transparent wordmark logo path.
    var logoPath: String?
    /// IMDb identifier, also used for intro-skip lookups.
    var imdbId: String?
    /// Collection fields are movie-only.
    var collectionId: Int?
    var collectionName: String?
    var collectionPosterPath: String?
    var collectionBackdropPath: String?
    /// MDBList ratings carried by a proxy batch item, when advertised. Never
    /// set by device TMDB; consumers check freshness against the title's age.
    var proxyRatings: LumeTitleRatings?
}

nonisolated struct TMDBCastMember: Hashable {
    let tmdbPersonId: Int
    let name: String
    let character: String?
    let profilePath: String?
    let order: Int
}

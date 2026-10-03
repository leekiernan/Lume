import Foundation

/// Poster-only recovery avoids the full-detail credits/images/ratings fanout.
nonisolated struct TMDBPosterResponse: Decodable {
    let posterPath: String?
    enum CodingKeys: String, CodingKey { case posterPath = "poster_path" }
}

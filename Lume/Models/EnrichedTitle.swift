import Foundation
import SwiftData

/// Common scalar/BLOB metadata only. Full-detail cast replacement and
/// provider-specific ratings, runtime and collection fields remain explicit.
nonisolated protocol EnrichedTitle: PersistentModel {
    var id: String { get }
    var tmdbId: Int? { get set }
    var proxyMetadataData: Data? { get set }
    var backdropPath: String? { get set }
    var posterPath: String? { get set }
    var posterCheckedAt: Date? { get set }
    var logoPath: String? { get set }
    var tagline: String? { get set }
    var contentRating: String? { get set }
    var imdbId: String? { get set }
    var plot: String? { get set }
    var genre: String? { get set }
    var similarTMDBIds: [Int]? { get set }
    var trailersData: Data? { get set }
    var externalRatingsData: Data? { get set }
    var ratingsEnrichedAt: Date? { get set }
    var tmdbEnrichedAt: Date? { get set }
    var tmdbArtworkEnrichedAt: Date? { get set }
    var castMembers: [CastMember] { get }
}

nonisolated extension Movie: EnrichedTitle {}
nonisolated extension Series: EnrichedTitle {}

nonisolated extension EnrichedTitle {
    /// Preserve the nil-on-disk representation for empty similar-title lists.
    var similarTitleIds: [Int] {
        get { similarTMDBIds ?? [] }
        set { similarTMDBIds = newValue.isEmpty ? nil : newValue }
    }

    var trailers: [TitleVideo] {
        get {
            guard let trailersData else { return [] }
            return (try? JSONDecoder().decode([TitleVideo].self, from: trailersData)) ?? []
        }
        set { trailersData = try? JSONEncoder().encode(newValue) }
    }

    var externalRatings: [ExternalRating] {
        get {
            guard let externalRatingsData else { return [] }
            return (try? JSONDecoder().decode([ExternalRating].self, from: externalRatingsData)) ?? []
        }
        set { externalRatingsData = try? JSONEncoder().encode(newValue) }
    }

    var orderedCast: [CastMember] {
        castMembers.sorted { $0.order < $1.order }
    }

    /// Never touches cast relationships or claims full-detail freshness.
    func applyCommonArtwork(_ details: TMDBTitleDetails) {
        backdropPath = details.backdropPath ?? backdropPath
        posterPath = details.posterPath ?? posterPath
        posterCheckedAt = details.proxyReceipt?.artworkAt ?? Date()
        logoPath = details.logoPath ?? logoPath
        tagline = details.tagline ?? tagline
        contentRating = details.contentRating ?? contentRating
        imdbId = details.imdbId ?? imdbId
        similarTitleIds = details.similarIDs
        trailers = details.videos
        if (plot ?? "").isEmpty, let overview = details.overview { plot = overview }
        if !details.genreNames.isEmpty { genre = details.genreNames.joined(separator: ", ") }
        tmdbArtworkEnrichedAt = details.proxyReceipt?.artworkAt ?? Date()
        recordProxyReceipt(details.proxyReceipt, fullDetails: false)
    }

    /// Keep the existing storage-clear contract: posters/provider fields stay;
    /// cast is explicitly deleted rather than merely disassociated.
    func clearCommonEnrichment(in context: ModelContext) {
        for cast in castMembers {
            context.delete(cast)
        }
        backdropPath = nil
        logoPath = nil
        tagline = nil
        contentRating = nil
        tmdbEnrichedAt = nil
        tmdbArtworkEnrichedAt = nil
        similarTMDBIds = nil
        trailersData = nil
        imdbId = nil
        externalRatingsData = nil
        ratingsEnrichedAt = nil
        proxyMetadataData = nil
    }
}

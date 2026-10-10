import Foundation
import SwiftData

private nonisolated struct AppliedProxyMetadata: Codable {
    var tmdb: LumeMetadataReceipt?
    var artwork: LumeMetadataReceipt?
}

nonisolated extension EnrichedTitle {
    /// Existing render-side artwork gates also need to discard proof from an
    /// edited account/language, without deleting the useful cached artwork.
    var effectiveTMDBArtworkDate: Date? {
        let date = tmdbArtworkEnrichedAt ?? tmdbEnrichedAt
        guard proxyMetadataData != nil else { return date }
        guard let context = modelContext,
              hasFreshTMDBArtwork(in: context, language: TMDBClient.preferredLanguageCode()) else { return nil }
        return date
    }

    /// Receipts are stored in the same transaction as the data they describe.
    /// A direct device fetch clears only the lane it actually replaced.
    func recordProxyReceipt(_ receipt: LumeMetadataReceipt?, fullDetails: Bool) {
        var applied = proxyMetadataData.flatMap { try? JSONDecoder().decode(AppliedProxyMetadata.self, from: $0) } ?? AppliedProxyMetadata()
        applied.artwork = receipt
        if fullDetails { applied.tmdb = receipt }
        proxyMetadataData = applied.tmdb == nil && applied.artwork == nil ? nil : try? JSONEncoder().encode(applied)
    }

    func hasFreshTMDBDetails(in context: ModelContext, language: String = TMDBClient.preferredLanguageCode(), now: Date = Date()) -> Bool {
        guard LumeMetadataReceipt.isFresh(tmdbEnrichedAt, now: now) else { return false }
        guard let data = proxyMetadataData else { return true } // Existing/device metadata.
        guard let applied = try? JSONDecoder().decode(AppliedProxyMetadata.self, from: data) else { return false }
        guard let receipt = applied.tmdb else { return true }
        return receipt.matches(source: LumeProxySource.snapshot(contentID: id, in: context), tmdbID: tmdbId, language: language)
    }

    func hasFreshTMDBArtwork(in context: ModelContext, language: String, now: Date = Date()) -> Bool {
        guard LumeMetadataReceipt.isFresh(tmdbArtworkEnrichedAt ?? tmdbEnrichedAt, now: now) else { return false }
        guard let data = proxyMetadataData else { return true }
        guard let applied = try? JSONDecoder().decode(AppliedProxyMetadata.self, from: data) else { return false }
        guard let receipt = tmdbArtworkEnrichedAt != nil ? applied.artwork : applied.tmdb else { return true }
        return receipt.matches(source: LumeProxySource.snapshot(contentID: id, in: context), tmdbID: tmdbId, language: language)
    }

    /// An unstamped provider write may replace some proxy-covered fields.
    /// Catalogue availability is deliberately insufficient to renew the proof.
    func invalidateProxyMetadata() {
        guard let data = proxyMetadataData else { return }
        let applied = try? JSONDecoder().decode(AppliedProxyMetadata.self, from: data)
        if applied?.tmdb != nil { tmdbEnrichedAt = nil }
        if applied?.artwork != nil { tmdbArtworkEnrichedAt = nil }
        proxyMetadataData = nil
    }

    /// Used only for rows with receipts; avoids extra work for ordinary bulk
    /// imports. These are provider-overwritable fields shared by both kinds.
    var proxyCoveredFields: [String?] {
        let common = [tmdbId.map(String.init), posterPath, plot, genre, tagline, imdbId, backdropPath, logoPath]
        if let movie = self as? Movie { return common + [String(movie.rating), movie.durationSecs.map(String.init)] }
        if let series = self as? Series { return common + [series.rating, series.cast] }
        return common
    }
}

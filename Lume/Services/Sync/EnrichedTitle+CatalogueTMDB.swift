import Foundation

nonisolated extension EnrichedTitle {
    /// Applies the TMDB ID a catalogue row carries (`raw`), given the value
    /// the previous catalogue import stored (`previous`).
    ///
    /// - A valid ID replaces the current one. When that changes an ID the
    ///   title was already enriched under, discard identity-owned metadata
    ///   and re-queue indexing, without erasing provider or user state.
    /// - A catalogue that stops sending the ID it supplied before withdraws it
    ///   (a corrected or withdrawn match, which an enriching proxy can do).
    /// - An ID the device resolved itself, where the catalogue never sent
    ///   one, is kept.
    func applyCatalogueTMDB(_ raw: String?, previous: String?) {
        if let supplied = Self.catalogueTMDB(raw) {
            guard tmdbId != supplied else { return }
            if tmdbId != nil { forgetTMDBEnrichment() }
            tmdbId = supplied
            return
        }
        guard let withdrawn = Self.catalogueTMDB(previous), tmdbId == withdrawn else { return }
        tmdbId = nil
        forgetTMDBEnrichment()
    }

    /// A catalogue `tmdb` value as an ID: positive integers only, since
    /// panels send `""`, `"0"` or nothing for "none".
    static func catalogueTMDB(_ raw: String?) -> Int? {
        guard let raw, let id = Int(raw.trimmingCharacters(in: .whitespaces)), id > 0 else { return nil }
        return id
    }

    private func forgetTMDBEnrichment() {
        restoreTMDBFallbacks()
        proxyMetadataData = nil
        tmdbEnrichedAt = nil
        tmdbArtworkEnrichedAt = nil
        ratingsEnrichedAt = nil
        backdropPath = nil
        posterPath = nil
        posterCheckedAt = nil
        logoPath = nil
        tagline = nil
        contentRating = nil
        imdbId = nil
        similarTMDBIds = nil
        trailersData = nil
        externalRatingsData = nil
        indexedAt = nil
        embeddingData = nil
        // Background catalogue sync must not delete cast faults held by an
        // open detail screen. Hide them now; the detail-owned apply replaces
        // and deletes the old rows safely, including when the new cast is empty.
        tmdbCastInvalidated = true
        if let movie = self as? Movie {
            movie.collectionId = nil
            movie.collectionName = nil
            movie.collectionPosterPath = nil
            movie.collectionBackdropPath = nil
        }
    }
}

import Foundation

/// The common metadata in Xtream's catalogue and per-series detail responses.
/// Sharing the application policy keeps a later sparse catalogue from erasing
/// useful fields filled by `get_series_info`.
nonisolated protocol XtreamSeriesMetadata {
    var cover: String? { get }
    var plot: String? { get }
    var cast: String? { get }
    var director: String? { get }
    var genre: String? { get }
    var releaseDate: String? { get }
    var rating: String? { get }
    var tmdb: String? { get }
}

nonisolated extension XtreamSeries: XtreamSeriesMetadata {}
nonisolated extension XtreamSeriesInfo: XtreamSeriesMetadata {}

nonisolated extension Series {
    /// Catalogue values may replace metadata; detail values only fill gaps.
    /// Neither response may erase metadata through absent/blank fields. Names,
    /// ordering, categories and episode-cache invalidation remain catalogue-owned.
    func applyProviderMetadata(_ metadata: some XtreamSeriesMetadata, fillMissing: Bool) {
        let covered = proxyMetadataData == nil ? nil : proxyCoveredFields
        defer {
            if let covered, covered != proxyCoveredFields { invalidateProxyMetadata() }
        }
        applyProviderField(metadata.cover, to: \.cover, fillMissing: fillMissing)
        applyProviderField(metadata.plot, to: \.plot, fillMissing: fillMissing)
        applyProviderField(metadata.cast, to: \.cast, fillMissing: fillMissing)
        applyProviderField(metadata.director, to: \.director, fillMissing: fillMissing)
        applyProviderField(metadata.releaseDate, to: \.releaseDate, fillMissing: fillMissing)
        applyProviderField(metadata.rating, to: \.rating, fillMissing: fillMissing)
        // Genre keeps the existing TMDB-first/provider-fallback policy.
        let genre = GenreParser.providerFallback(current: genre, provider: metadata.genre)
        applyProviderField(genre, to: \.genre, fillMissing: true)
        // Never withdrawn: `get_series_info` fills the same field, and the stored
        // value doesn't say which response set it, so an absent catalogue ID
        // can't tell a withdrawal from a sparse row. A corrected ID replaces the
        // old one and re-enriches (movies, catalogue-only, also withdraw).
        if let raw = metadata.tmdb, let identifier = Self.catalogueTMDB(raw) {
            applyProviderField(raw, to: \.tmdb, fillMissing: fillMissing)
            if !fillMissing {
                applyCatalogueTMDB(raw, previous: nil)
            } else if tmdbId == nil {
                tmdbId = identifier
            }
        }
    }

    private func applyProviderField(_ value: String?, to keyPath: ReferenceWritableKeyPath<Series, String?>, fillMissing: Bool) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let current = self[keyPath: keyPath]
        if fillMissing, let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if current != value { self[keyPath: keyPath] = value }
    }
}

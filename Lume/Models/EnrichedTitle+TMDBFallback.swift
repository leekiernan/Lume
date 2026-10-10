import Foundation

/// Shared fields are not exclusively TMDB-owned. Remember exactly what a
/// TMDB write replaced so withdrawing that identity can restore provider data.
/// Legacy rows without this optional provenance are deliberately not guessed.
nonisolated enum TMDBFallbackField: String, Codable {
    case plot, genre, runtime, rating, cast
}

private nonisolated struct TMDBFallbackChange: Codable {
    let previous: String?
    let applied: String
}

nonisolated extension EnrichedTitle {
    func recordTMDBFallback(_ field: TMDBFallbackField, previous: String?, applied: String) {
        guard previous != applied else { return }
        var changes = tmdbFallbackChanges
        // Repeated enrichment retains the original provider value. A provider
        // edit since our last write becomes the new value to restore instead.
        let original: String? = if let retained = changes[field.rawValue], retained.applied == previous {
            retained.previous // Nil means the provider had no value.
        } else {
            previous
        }
        changes[field.rawValue] = TMDBFallbackChange(previous: original, applied: applied)
        tmdbFallbackData = try? JSONEncoder().encode(changes)
    }

    /// Restore only fields which still hold the value we wrote. Later provider
    /// edits, watch state, downloads and episode caches are never touched.
    func restoreTMDBFallbacks() {
        let changes = tmdbFallbackChanges
        if let change = changes[TMDBFallbackField.plot.rawValue], plot == change.applied { plot = change.previous }
        if let change = changes[TMDBFallbackField.genre.rawValue], genre == change.applied { genre = change.previous }
        if let movie = self as? Movie {
            if let change = changes[TMDBFallbackField.runtime.rawValue], movie.durationSecs.map(String.init) == change.applied {
                movie.durationSecs = change.previous.flatMap(Int.init)
            }
            if let change = changes[TMDBFallbackField.rating.rawValue], String(movie.rating) == change.applied {
                movie.rating = change.previous.flatMap(Double.init) ?? 0
            }
        }
        if let series = self as? Series {
            if let change = changes[TMDBFallbackField.cast.rawValue], series.cast == change.applied { series.cast = change.previous }
            if let change = changes[TMDBFallbackField.rating.rawValue], series.rating == change.applied { series.rating = change.previous }
        }
        tmdbFallbackData = nil
    }

    private var tmdbFallbackChanges: [String: TMDBFallbackChange] {
        guard let tmdbFallbackData else { return [:] }
        return (try? JSONDecoder().decode([String: TMDBFallbackChange].self, from: tmdbFallbackData)) ?? [:]
    }
}

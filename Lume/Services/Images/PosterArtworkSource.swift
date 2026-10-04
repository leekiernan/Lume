import Foundation

/// Provider posters remain preferred. TMDB is a stored-metadata fallback only;
/// resolving a source never performs enrichment or any other network request.
nonisolated struct PosterArtworkSource: Hashable {
    let providerURL: URL?
    let tmdbURL: URL?
    let diagnostic: String?

    init(provider: String?, posterPath: String?) {
        let raw = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        providerURL = Self.remoteURL(raw)

        tmdbURL = TMDBClient.posterURL(posterPath)

        if providerURL == nil {
            let reason = raw.isEmpty ? "missing provider URL" : "invalid provider URL"
            diagnostic = reason + (tmdbURL == nil ? "; no stored TMDB poster" : "; using stored TMDB poster")
        } else {
            diagnostic = nil
        }
    }

    var primaryURL: URL? {
        providerURL ?? tmdbURL
    }

    /// Only a failed provider request can advance to another source. An absent
    /// provider already uses TMDB as primary, so never retry that same URL.
    func url(afterPrimaryFailure failed: Bool) -> URL? {
        guard failed else { return primaryURL }
        guard providerURL != nil, tmdbURL != primaryURL else { return nil }
        return tmdbURL
    }

    private static func remoteURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

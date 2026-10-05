import Foundation

/// URL mechanics only. Callers still choose the artwork kind and pixel budget;
/// provider URLs and unknown TMDB formats are never resized here.
nonisolated enum TMDBArtworkURL {
    static let baseURL = "https://image.tmdb.org/t/p/"

    static func poster(_ path: String?, size: String = "w500") -> URL? {
        let path = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.dropFirst().contains("/"), !path.contains("?"), !path.contains("#"),
              ["jpg", "jpeg", "png", "webp"].contains((path as NSString).pathExtension.lowercased())
        else { return nil }
        return URL(string: baseURL + size + path)
    }

    static func resized(_ url: URL?, to size: String, allowedSizes: [String]) -> URL? {
        guard let url, url.host == "image.tmdb.org" else { return url }
        var components = url.pathComponents
        guard components.count == 5, components[1] == "t", components[2] == "p",
              allowedSizes.contains(components[3]),
              ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
        else { return url }
        components[3] = size
        var result = URLComponents(url: url, resolvingAgainstBaseURL: false)
        result?.path = "/" + components.dropFirst().joined(separator: "/")
        return result?.url ?? url
    }
}

nonisolated extension TMDBClient {
    /// Posters have their own rendition family, separate from backdrops.
    static func posterURL(_ path: String?, size: String = "w500") -> URL? {
        TMDBArtworkURL.poster(path, size: size)
    }
}

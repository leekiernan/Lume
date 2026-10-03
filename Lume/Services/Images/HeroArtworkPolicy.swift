import Foundation

/// Composition and pixel sizing are independent of carousel/playback state.
nonisolated enum HeroArtworkPolicy {
    static let landscapeRatio: CGFloat = 16 / 9
    static let portraitRatio: CGFloat = 2 / 3

    static func portraitURL(_ poster: URL?, width: CGFloat) -> URL? {
        width < 600 ? poster : nil
    }

    static func posterURL(_ url: URL?, pixelWidth: CGFloat) -> URL? {
        guard let url, url.host == "image.tmdb.org" else { return url }
        var components = url.pathComponents
        guard components.count == 5, components[1] == "t", components[2] == "p",
              ["w92", "w154", "w185", "w342", "w500", "w780", "original"].contains(components[3]),
              ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
        else { return url }
        components[3] = pixelWidth <= 342 ? "w342" : pixelWidth <= 500 ? "w500" : pixelWidth <= 780 ? "w780" : "original"
        var result = URLComponents(url: url, resolvingAgainstBaseURL: false)
        result?.path = "/" + components.dropFirst().joined(separator: "/")
        return result?.url ?? url
    }

    /// Stable from the first layout pass, including the warm-start placeholder.
    static func heroHeight(width: CGFloat) -> CGFloat {
        width < 600 ? max(540, width / landscapeRatio + 320) : 800
    }

    /// Preserve the complete landscape composition above compact hero copy.
    /// Wide surfaces keep their existing immersive artwork geometry.
    static func artworkHeight(width: CGFloat, heroHeight: CGFloat) -> CGFloat {
        width < 600 ? min(heroHeight, width / landscapeRatio) : heroHeight
    }

    /// Longest decoded edge needed for a landscape image to fill this region.
    static func decodePoints(width: CGFloat, height: CGFloat, sourceRatio: CGFloat = landscapeRatio) -> CGFloat {
        max(width, height * sourceRatio) * max(1, 1 / sourceRatio)
    }

    /// TMDB sizes resize the same composition; they are not alternative crops.
    /// Restrict rewriting to known TMDB raster backdrop URLs, never provider art.
    static func backdropURL(_ url: URL?, pixelWidth: CGFloat) -> URL? {
        guard let url, url.host == "image.tmdb.org" else { return url }
        var components = url.pathComponents
        guard components.count == 5, components[1] == "t", components[2] == "p",
              ["w300", "w780", "w1280", "w1920", "original"].contains(components[3]),
              ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
        else { return url }
        let size = pixelWidth <= 300 ? "w300" : pixelWidth <= 780 ? "w780" : pixelWidth <= 1280 ? "w1280" : "original"
        components[3] = size
        var result = URLComponents(url: url, resolvingAgainstBaseURL: false)
        result?.path = "/" + components.dropFirst().joined(separator: "/")
        return result?.url ?? url
    }
}

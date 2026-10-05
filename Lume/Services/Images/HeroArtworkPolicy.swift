import Foundation

/// Composition and pixel sizing are independent of carousel/playback state.
nonisolated enum HeroArtworkPolicy {
    static let compactWidthThreshold: CGFloat = 600
    static let compactFadeStart: CGFloat = 0.65

    static func isCompact(width: CGFloat) -> Bool {
        width < compactWidthThreshold
    }

    static let landscapeRatio: CGFloat = 16 / 9
    static let portraitRatio: CGFloat = 2 / 3
    static let portraitZoom: CGFloat = 1.25

    nonisolated struct Rendition: Equatable {
        let url: URL?
        /// CachedAsyncImage accepts points and applies the display scale itself.
        let decodeSizeInPoints: CGFloat
        /// ImagePipeline prefetch accepts pixels; use this for the same cache key.
        let decodeSizeInPixels: CGFloat
    }

    static func rendition(
        url: URL?, width: CGFloat, height: CGFloat,
        sourceRatio: CGFloat = landscapeRatio, zoom: CGFloat = 1, displayScale: CGFloat
    ) -> Rendition {
        let points = decodePoints(width: width, height: height, sourceRatio: sourceRatio) * zoom
        let pixels = points * displayScale
        let sizedURL = sourceRatio < 1 ? posterURL(url, pixelWidth: pixels * sourceRatio) : backdropURL(url, pixelWidth: pixels)
        return Rendition(url: sizedURL, decodeSizeInPoints: points, decodeSizeInPixels: pixels)
    }

    static func portraitURL(_ poster: URL?, width: CGFloat) -> URL? {
        isCompact(width: width) ? poster : nil
    }

    static func posterURL(_ url: URL?, pixelWidth: CGFloat) -> URL? {
        let size = pixelWidth <= 342 ? "w342" : pixelWidth <= 500 ? "w500" : pixelWidth <= 780 ? "w780" : "original"
        return TMDBArtworkURL.resized(url, to: size, allowedSizes: ["w92", "w154", "w185", "w342", "w500", "w780", "original"])
    }

    /// Stable from the first layout pass, including the warm-start placeholder.
    static func heroHeight(width: CGFloat, portraitComposition: Bool = false) -> CGFloat {
        guard isCompact(width: width) else { return 800 }
        let baseline = max(540, width / landscapeRatio + 320)
        return portraitComposition ? min(780, baseline * portraitZoom) : baseline
    }

    /// Preserve the complete landscape composition above compact hero copy.
    /// Wide surfaces keep their existing immersive artwork geometry.
    static func artworkHeight(width: CGFloat, heroHeight: CGFloat) -> CGFloat {
        isCompact(width: width) ? min(heroHeight, width / landscapeRatio) : heroHeight
    }

    /// Longest decoded edge needed for a landscape image to fill this region.
    static func decodePoints(width: CGFloat, height: CGFloat, sourceRatio: CGFloat = landscapeRatio) -> CGFloat {
        max(width, height * sourceRatio) * max(1, 1 / sourceRatio)
    }

    /// TMDB sizes resize the same composition; they are not alternative crops.
    /// Restrict rewriting to known TMDB raster backdrop URLs, never provider art.
    static func backdropURL(_ url: URL?, pixelWidth: CGFloat) -> URL? {
        let size = pixelWidth <= 300 ? "w300" : pixelWidth <= 780 ? "w780" : pixelWidth <= 1280 ? "w1280" : "original"
        return TMDBArtworkURL.resized(url, to: size, allowedSizes: ["w300", "w780", "w1280", "w1920", "original"])
    }
}

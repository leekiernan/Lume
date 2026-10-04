import Foundation

/// Source preference is independent of decode budgets and network outcomes.
/// A missing backdrop uses the provider poster; a failed backdrop retains the
/// existing failure placeholder rather than starting a second artwork request.
nonisolated struct DetailArtworkSource {
    let url: URL?
    let sourceRatio: CGFloat

    init(backdropURL: URL?, posterFallbackURL: URL?) {
        url = backdropURL ?? posterFallbackURL
        sourceRatio = backdropURL == nil && posterFallbackURL != nil
            ? HeroArtworkPolicy.portraitRatio : HeroArtworkPolicy.landscapeRatio
    }
}

nonisolated enum DetailArtworkPolicy {
    /// Longest-edge decode budget. A detail backdrop sits under a heavy
    /// scrim with the title and actions over it, so it stops short of UHD: a
    /// 4K decode held ~33 MB in the image memory cache per detail page, and
    /// push chains (detail → similar → detail) evicted the posters around
    /// them. 2560px is ~15 MB, and shows on a 4K TV scaled 1.5×. Not a device
    /// setting, and the Home hero keeps its own budget.
    static let maximumPixelEdge: CGFloat = 2560

    /// Decode widths the requirement is rounded up to. Without them every
    /// point of a window resize, Stage Manager change or rotation was a new
    /// decode size, so a new cache key: the backdrop dropped to its
    /// placeholder and decoded again each time. Common output widths, so HD
    /// screens land exactly on 1920.
    static let decodeLadder: [CGFloat] = [320, 480, 640, 960, 1280, 1920, maximumPixelEdge]

    static func rendition(
        for source: DetailArtworkSource, width: CGFloat, height: CGFloat, displayScale: CGFloat
    ) -> HeroArtworkPolicy.Rendition? {
        guard width.isFinite, height.isFinite, displayScale.isFinite,
              width > 0, height > 0, displayScale > 0 else { return nil }
        let required = HeroArtworkPolicy.decodePoints(width: width, height: height, sourceRatio: source.sourceRatio) * displayScale
        let pixels = decodeLadder.first { $0 >= required } ?? maximumPixelEdge
        let points = pixels / displayScale
        guard points.isFinite else { return nil }
        let url = source.sourceRatio < 1
            ? HeroArtworkPolicy.posterURL(source.url, pixelWidth: pixels * source.sourceRatio)
            : HeroArtworkPolicy.backdropURL(source.url, pixelWidth: pixels)
        return HeroArtworkPolicy.Rendition(url: url, decodeSizeInPoints: points, decodeSizeInPixels: pixels)
    }
}

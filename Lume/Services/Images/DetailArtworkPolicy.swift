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
    /// Supports UHD landscape output, while bounding extreme portrait fill
    /// crops and large Retina windows. This is a longest-edge pixel budget,
    /// not a device/model setting or a change to the hero's layout.
    static let maximumPixelEdge: CGFloat = 4096

    /// Decode widths the requirement is rounded up to. Without them every
    /// point of a window resize, Stage Manager change or rotation was a new
    /// decode size, so a new cache key: the backdrop dropped to its
    /// placeholder and decoded again each time. Common output widths, so HD
    /// and UHD screens land exactly on 1920 and 3840.
    static let decodeLadder: [CGFloat] = [320, 480, 640, 960, 1280, 1920, 2560, 3840, maximumPixelEdge]

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

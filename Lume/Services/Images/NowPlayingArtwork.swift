import CoreGraphics
import Foundation

/// Artwork sizing for the system MediaPlayer surfaces, independent of playback
/// transport. Large requests keep the portrait; compact icons use its centre.
nonisolated enum NowPlayingArtwork {
    /// MediaPlayer does not identify the presentation surface. Small square
    /// requests are a compact-icon heuristic; larger requests keep source aspect.
    static func usesCompactCrop(for size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return false }
        let longest = max(size.width, size.height)
        return longest <= 256 && min(size.width, size.height) / longest >= 0.95
    }

    static func centeredSquare(_ image: CGImage) -> CGImage? {
        let side = min(image.width, image.height)
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                          width: side, height: side)
        return image.cropping(to: rect)
    }
}

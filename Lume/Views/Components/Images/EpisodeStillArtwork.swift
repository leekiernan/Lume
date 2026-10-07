import SwiftUI

/// Artwork only: episode labels, progress, badges and actions stay with the
/// card. All surfaces share a stable brand tile while loading or without art.
struct EpisodeStillArtwork<Placeholder: View>: View {
    let title: String
    let url: URL?
    let maxPixelSize: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        CachedAsyncImage(url: url, maxPixelSize: maxPixelSize) { phase in
            switch phase {
            case let .success(image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .empty where url != nil:
                tile.overlay { ProgressView() }
            default:
                tile.overlay { placeholder() }
            }
        }
    }

    private var tile: some View {
        Rectangle().fill(PosterTitleTile.color(for: title))
    }
}

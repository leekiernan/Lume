import SwiftUI

/// Geometry belongs to the rendering surface, not to the metadata/network actor.
struct HeroArtworkImage: View {
    let url: URL?
    var sourceRatio = HeroArtworkPolicy.landscapeRatio
    var zoom: CGFloat = 1
    var onFailure: (() -> Void)?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let points = HeroArtworkPolicy.decodePoints(width: proxy.size.width, height: proxy.size.height, sourceRatio: sourceRatio) * zoom
            CachedAsyncImage(
                url: sourceRatio < 1
                    ? HeroArtworkPolicy.posterURL(url, pixelWidth: points * sourceRatio * displayScale)
                    : HeroArtworkPolicy.backdropURL(url, pixelWidth: points * displayScale),
                maxPixelSize: points
            ) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else if case .failure = phase {
                    Color.clear.onAppear { onFailure?() }
                } else {
                    Color.clear
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(zoom)
            .clipped()
        }
    }
}

import SwiftUI

/// Shared bounded rendering; detail screens retain layout, scrims, actions and
/// loading machines. Only the platform's existing placeholder treatment varies.
struct DetailBackdropArtwork: View {
    enum Appearance {
        case standard, television
    }

    let backdropURL: URL?
    let posterFallbackURL: URL?
    var fallbackSymbol = "film"
    var appearance: Appearance = .standard
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let source = DetailArtworkSource(backdropURL: backdropURL, posterFallbackURL: posterFallbackURL)
            if let rendition = DetailArtworkPolicy.rendition(
                for: source, width: proxy.size.width, height: proxy.size.height, displayScale: displayScale
            ) {
                CachedAsyncImage(url: rendition.url, maxPixelSize: rendition.decodeSizeInPoints) { phase in
                    switch phase {
                    case .empty:
                        placeholder.overlay { if appearance == .standard { ProgressView() } }
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    case .failure:
                        placeholder.overlay { if appearance == .standard { failureSymbol } }
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                // A zero-size initial layout should not fetch/decode artwork.
                placeholder
            }
        }
    }

    /// tvOS: the ambient glow the art loads over (the detail boards);
    /// elsewhere the existing flat fill.
    @ViewBuilder
    private var placeholder: some View {
        if appearance == .television {
            LumeAmbientBackground(style: .backdrop)
        } else {
            Rectangle().fill(.gray.opacity(0.25))
        }
    }

    private var failureSymbol: some View {
        Image(systemName: fallbackSymbol)
            .font(.largeTitle)
            .foregroundStyle(.secondary)
    }
}

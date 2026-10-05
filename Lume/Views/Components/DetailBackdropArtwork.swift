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

    private var placeholderColor: Color {
        appearance == .television ? .black.opacity(0.6) : .gray.opacity(0.25)
    }

    var body: some View {
        GeometryReader { proxy in
            let source = DetailArtworkSource(backdropURL: backdropURL, posterFallbackURL: posterFallbackURL)
            if let rendition = DetailArtworkPolicy.rendition(
                for: source, width: proxy.size.width, height: proxy.size.height, displayScale: displayScale
            ) {
                CachedAsyncImage(url: rendition.url, maxPixelSize: rendition.decodeSizeInPoints) { phase in
                    switch phase {
                    case .empty:
                        Rectangle().fill(placeholderColor).overlay { ProgressView() }
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    case .failure:
                        Rectangle().fill(placeholderColor).overlay { failureSymbol }
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                // A zero-size initial layout should not fetch/decode artwork.
                Rectangle().fill(placeholderColor)
            }
        }
    }

    private var failureSymbol: some View {
        Image(systemName: fallbackSymbol)
            .font(appearance == .television ? .system(size: 80) : .largeTitle)
            .foregroundStyle(appearance == .television ? AnyShapeStyle(.white.opacity(0.4)) : AnyShapeStyle(.secondary))
    }
}

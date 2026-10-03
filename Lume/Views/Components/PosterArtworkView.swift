import SwiftUI

/// One poster lifecycle for movie and series cards on every platform. Cached
/// images, cancellation, downsampling and retries stay owned by CachedAsyncImage.
struct PosterArtworkView<Content: View>: View {
    let source: PosterArtworkSource
    let maxPixelSize: CGFloat
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    init(provider: String?, posterPath: String?, maxPixelSize: CGFloat, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        source = PosterArtworkSource(provider: provider, posterPath: posterPath)
        self.maxPixelSize = maxPixelSize
        self.content = content
    }

    var body: some View {
        CachedAsyncImage(url: source.primaryURL, maxPixelSize: maxPixelSize) { phase in
            if case .failure = phase, let fallback = source.url(afterPrimaryFailure: true) {
                CachedAsyncImage(url: fallback, maxPixelSize: maxPixelSize, content: content)
            } else {
                content(phase)
            }
        }
        .task(id: source.diagnostic) {
            if let diagnostic = source.diagnostic {
                await ImagePipeline.shared.notePosterSourceIssue(diagnostic)
            }
        }
    }
}

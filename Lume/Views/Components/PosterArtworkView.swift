import SwiftData
import SwiftUI

/// One poster lifecycle for movie and series cards on every platform. Cached
/// images, cancellation, downsampling and retries stay owned by CachedAsyncImage.
struct PosterArtworkView<Content: View>: View {
    let provider: String?
    let posterPath: String?
    let request: PosterArtworkRequest?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @State private var recovered: Recovery?

    private struct Recovery {
        let key: PosterEnrichmentQueue.Key
        let path: String?
    }

    private var recoveryKey: PosterEnrichmentQueue.Key? {
        guard let request, profiles?.isSwitching != true,
              !restriction.hides(categoryID: request.categoryID) else { return nil }
        return .init(catalog: ObjectIdentifier(modelContext.container), request: request,
                     profile: profiles?.activeProfileID ?? ActiveProfileStore.current, visibility: restriction.visibilityToken)
    }

    private var source: PosterArtworkSource {
        let path = recovered?.key == recoveryKey ? recovered?.path : nil
        let stored = PosterArtworkSource(provider: provider, posterPath: posterPath)
        return stored.tmdbURL == nil ? PosterArtworkSource(provider: provider, posterPath: path) : stored
    }

    let maxPixelSize: CGFloat
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    init(provider: String?, posterPath: String?, request: PosterArtworkRequest? = nil, maxPixelSize: CGFloat, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.provider = provider
        self.posterPath = posterPath
        self.request = request
        self.maxPixelSize = maxPixelSize
        self.content = content
    }

    var body: some View {
        CachedAsyncImage(url: source.primaryURL, maxPixelSize: maxPixelSize) { phase in
            if case .failure = phase, let fallback = source.url(afterPrimaryFailure: true) {
                CachedAsyncImage(url: fallback, maxPixelSize: maxPixelSize, content: content)
            } else if case .failure = phase, source.tmdbURL == nil {
                content(phase)
                    .task(id: recoveryKey) {
                        guard let key = recoveryKey else { return }
                        let recovery = PosterArtworkRecovery(container: modelContext.container)
                        let visibility = restriction
                        let result = await PosterEnrichmentQueue.shared.lookup(key) {
                            try await recovery.lookup(key.request, profile: key.profile, restriction: visibility)
                        }
                        guard !Task.isCancelled, key.profile == ActiveProfileStore.current, let result else { return }
                        recovered = Recovery(key: key, path: result.path)
                    }
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

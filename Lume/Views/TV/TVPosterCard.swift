import SwiftUI

#if os(tvOS)
    /// Detail-rail layout remains tvOS-specific; only artwork ownership is shared.
    struct TVPosterCard: View {
        let item: HomeMediaItem
        var badge: String?

        var body: some View {
            PosterArtworkView(
                provider: item.imageURL?.absoluteString, posterPath: item.posterPath,
                request: item.posterRecoveryRequest, maxPixelSize: PosterCardMetrics.posterHeight
            ) { phase in
                PosterArtworkContent(phase: phase, title: item.title)
            }
            .frame(width: PosterCardMetrics.posterWidth, height: PosterCardMetrics.posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius, style: .continuous))
            .posterBadge(badge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(item.title))
        }
    }
#endif

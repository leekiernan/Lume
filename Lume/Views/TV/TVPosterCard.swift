import SwiftUI

#if os(tvOS)
    /// Detail-rail layout remains tvOS-specific; only artwork ownership is shared.
    struct TVPosterCard: View {
        let item: HomeMediaItem
        var badge: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                PosterArtworkView(
                    provider: item.imageURL?.absoluteString, posterPath: item.posterPath,
                    request: item.posterRecoveryRequest, maxPixelSize: PosterCardMetrics.posterHeight
                ) { phase in
                    PosterArtworkContent(
                        phase: phase, fallbackSymbol: item.posterRecoveryRequest?.kind == .series ? "tv" : "film",
                        placeholderFill: .white.opacity(0.08), fallbackForeground: .white.opacity(0.5),
                        fallbackFont: .system(size: 56)
                    )
                }
                .frame(width: TVDetailMetrics.posterCardWidth, height: TVDetailMetrics.posterCardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .posterBadge(badge)

                Text(item.title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: TVDetailMetrics.posterCardWidth, alignment: .leading)
            }
        }
    }
#endif

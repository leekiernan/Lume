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
                    switch phase {
                    case .empty:
                        Rectangle().fill(Color.white.opacity(0.08)).overlay { ProgressView() }
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Rectangle().fill(Color.white.opacity(0.08))
                            .overlay {
                                Image(systemName: item.posterRecoveryRequest?.kind == .series ? "tv" : "film")
                                    .font(.system(size: 56))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                    @unknown default:
                        EmptyView()
                    }
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

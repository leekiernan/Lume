import SwiftUI

/// Detail-specific layout; poster source/recovery lifecycle is shared with
/// library cards without changing navigation, badges or focus styling.
struct DetailPosterCard: View {
    let title: String
    let imageURL: URL?
    var posterPath: String?
    var request: PosterArtworkRequest?
    var badge: String?
    var isSeries: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: PosterCardMetrics.titleSpacing) {
            PosterArtworkView(
                provider: imageURL?.absoluteString, posterPath: posterPath,
                request: request, maxPixelSize: PosterCardMetrics.posterHeight
            ) { phase in
                switch phase {
                case .empty:
                    Rectangle().fill(Color.gray.opacity(0.3)).overlay { ProgressView() }
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle().fill(Color.gray.opacity(0.3))
                        .overlay {
                            Image(systemName: isSeries ? "tv" : "film")
                                .foregroundStyle(.secondary)
                                .font(.largeTitle)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .posterArtworkFrame(fillsWidth: false)
            .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))
            .posterBadge(badge)
            #if !os(tvOS)
                .shadow(radius: 2)
            #endif

            Text(title)
                .font(PosterCardMetrics.titleFont)
                .lineLimit(2)
                .posterTitleFrame(fillsWidth: false)
        }
    }
}

extension DetailPosterCard {
    init(item: HomeMediaItem, badge: String? = nil) {
        self.init(title: item.title, imageURL: item.imageURL, posterPath: item.posterPath,
                  request: item.posterRecoveryRequest, badge: badge, isSeries: item.posterRecoveryRequest?.kind == .series)
    }
}

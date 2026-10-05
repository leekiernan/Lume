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
        posterCard
    }

    var posterCard: PosterCard {
        PosterCard(title: title, provider: imageURL?.absoluteString, posterPath: posterPath,
                   request: request, fallbackSymbol: isSeries ? "tv" : "film", badge: badge)
    }
}

extension DetailPosterCard {
    init(item: HomeMediaItem, badge: String? = nil) {
        self.init(title: item.title, imageURL: item.imageURL, posterPath: item.posterPath,
                  request: item.posterRecoveryRequest, badge: badge, isSeries: item.posterRecoveryRequest?.kind == .series)
    }
}

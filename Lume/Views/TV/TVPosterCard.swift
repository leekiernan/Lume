import SwiftUI

#if os(tvOS)
    /// Detail-rail layout remains tvOS-specific; only artwork ownership is shared.
    struct TVPosterCard: View {
        let item: HomeMediaItem
        var badge: String?

        var body: some View {
            PosterCard(title: item.title, provider: item.imageURL?.absoluteString, posterPath: item.posterPath,
                       request: item.posterRecoveryRequest, badge: badge)
                .environment(\.posterPresentation, .detail)
        }
    }
#endif

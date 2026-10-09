import SwiftUI

/// Programme imagery shares the episode-image pipeline and brand placeholder.
/// Channel logos remain a fitted fallback, never cropped like programme art.
struct LiveTVProgrammeArtwork: View {
    let title: String
    let artworkURL: String?
    let logoURL: String?
    let maxPixelSize: CGFloat

    var body: some View {
        EpisodeStillArtwork(title: title, url: artworkURL.flatMap(URL.init(string:)), maxPixelSize: maxPixelSize) {
            CachedAsyncImage(url: logoURL.flatMap(URL.init(string:)), maxPixelSize: 240) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(PosterCardMetrics.liveLogoInset)
        }
        .accessibilityHidden(true)
    }
}

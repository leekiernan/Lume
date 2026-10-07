import SwiftUI

/// One landscape surface for channel and programme rails. The caption always
/// stays visible: unlike a VOD poster, live artwork cannot explain the schedule.
struct LiveTVHubCard: View {
    let channel: LiveTVHubChannel
    let slot: EPGSlot?
    let now: Date
    var programmeArtwork = false

    private var titleFont: Font {
        #if os(tvOS)
            .system(size: 24, weight: .semibold)
        #else
            .headline
        #endif
    }

    private var channelFont: Font {
        #if os(tvOS)
            .system(size: 20)
        #else
            .subheadline
        #endif
    }

    private var timeFont: Font {
        #if os(tvOS)
            .system(size: 18)
        #else
            .caption
        #endif
    }

    #if os(tvOS)
        static let width: CGFloat = 360
        static let height: CGFloat = 284
    #else
        static let width: CGFloat = 240
        static let height: CGFloat = 218
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                LumeAmbientBackground(style: .hero)
                if programmeArtwork, let raw = slot?.artworkURL, let url = URL(string: raw) {
                    CachedAsyncImage(url: url, maxPixelSize: Self.width * 2) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            logo
                        }
                    }
                } else {
                    logo
                }
            }
            .frame(width: Self.width, height: Self.width * 9 / 16)
            .clipped()
            .overlay(alignment: .bottom) {
                if let slot, slot.start <= now, now < slot.end {
                    ProgressView(value: progress(slot))
                        .tint(.lumeAccent)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: PosterCardMetrics.cornerRadius))

            VStack(alignment: .leading, spacing: 4) {
                Text(slot?.title ?? channel.name)
                    .font(titleFont)
                    .lineLimit(1)
                Text(channel.name)
                    .font(channelFont)
                    .foregroundStyle(.lumeTextSecondary)
                    .lineLimit(1)
                if let slot {
                    HStack(spacing: 4) {
                        Text(slot.start, style: .time)
                        Text("–")
                        Text(slot.end, style: .time)
                    }
                    .font(timeFont)
                    .foregroundStyle(.lumeTextTertiary)
                } else {
                    Text("No EPG data").font(timeFont).foregroundStyle(.lumeTextTertiary)
                }
            }
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private var logo: some View {
        CachedAsyncImage(url: channel.logoURL.flatMap(URL.init(string:)), maxPixelSize: 240) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(PosterCardMetrics.liveLogoInset)
    }

    private func progress(_ slot: EPGSlot) -> Double {
        guard slot.end > slot.start else { return 0 }
        return min(max(now.timeIntervalSince(slot.start) / slot.end.timeIntervalSince(slot.start), 0), 1)
    }
}

extension View {
    @ViewBuilder func liveTVHubCardStyle() -> some View {
        #if os(tvOS)
            buttonStyle(TVCardButtonStyle())
        #else
            buttonStyle(.plain)
        #endif
    }
}

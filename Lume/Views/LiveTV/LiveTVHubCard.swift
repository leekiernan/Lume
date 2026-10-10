import SwiftUI

/// One landscape surface for channel and programme rails. The caption always
/// stays visible: unlike a VOD poster, live artwork cannot explain the schedule.
struct LiveTVHubCard: View {
    let channel: LiveTVHubChannel
    let slot: EPGSlot?
    let now: Date

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
            LiveTVProgrammeArtwork(title: slot?.title ?? channel.name, artworkURL: slot?.artworkURL,
                                   logoURL: channel.logoURL, maxPixelSize: Self.width * 2)
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

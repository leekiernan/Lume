import SwiftUI

/// The same channel/now/next description in lists and search. The wrappers
/// retain playback, menus and native focus; density is a presentation choice.
struct LiveChannelRowContent: View {
    enum Density {
        case standard, television
    }

    let stream: LiveStream
    var epg: ChannelEPG?
    var categoryName: String?
    var upcoming: EPGSlot?
    var density: Density = .standard

    private var isTV: Bool {
        density == .television
    }

    private var logoSize: CGFloat {
        isTV ? 84 : 60
    }

    private var secondary: AnyShapeStyle {
        isTV ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.secondary)
    }

    private var tertiary: AnyShapeStyle {
        isTV ? AnyShapeStyle(Color.white.opacity(0.45)) : AnyShapeStyle(.tertiary)
    }

    private var programmeStyle: AnyShapeStyle {
        isTV ? secondary : AnyShapeStyle(.primary)
    }

    private var timeFont: Font {
        isTV ? .system(size: 22) : .caption2
    }

    var body: some View {
        HStack(spacing: isTV ? 24 : 12) {
            logo
            VStack(alignment: .leading, spacing: isTV ? 6 : 4) {
                if let categoryName { LiveCategoryLabel(name: categoryName) }
                Text(stream.name)
                    .font(isTV ? .system(size: 30, weight: .semibold) : .headline)
                    .foregroundStyle(isTV ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                programme
                if stream.supportsCatchup {
                    if isTV {
                        Label("Catchup: \(stream.catchupArchiveDays)d", systemImage: "clock.arrow.circlepath")
                            .font(timeFont)
                            .foregroundStyle(.lumeAccent)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Catchup: \(stream.catchupArchiveDays)d")
                        }
                        .font(timeFont)
                        .foregroundStyle(.lumeAccent)
                    }
                }
            }
            if isTV { Spacer(minLength: 0) } else { Spacer() }
            Image(systemName: "chevron.right")
                .font(isTV ? .system(size: 24, weight: .semibold) : .caption)
                .foregroundStyle(isTV ? tertiary : secondary)
        }
    }

    @ViewBuilder
    private var programme: some View {
        if let upcoming {
            programmeTitle(upcoming.title)
            Text(upcoming.start, format: .dateTime.weekday(.abbreviated).hour().minute())
                .font(isTV ? .system(size: 22, weight: .semibold) : .caption2)
                .foregroundStyle(.lumeAccent)
        } else if let current = epg?.current {
            programmeTitle(current.title)
            HStack(spacing: isTV ? 6 : 4) {
                Text(current.start, style: .time)
                Text("–")
                Text(current.end, style: .time)
            }
            .font(timeFont)
            .foregroundStyle(isTV ? tertiary : secondary)
            if let next = epg?.next {
                HStack(spacing: isTV ? 6 : 4) {
                    Text("Next:")
                    Text(next.title).lineLimit(1)
                    Text(next.start, style: .time)
                        .foregroundStyle(tertiary)
                }
                .font(timeFont)
                .foregroundStyle(isTV ? tertiary : secondary)
            }
        } else if stream.epgChannelId?.isEmpty == false {
            Text("No EPG data")
                .font(isTV ? timeFont : .caption)
                .foregroundStyle(tertiary)
        } else {
            Text("Live")
                .font(isTV ? timeFont : .caption)
                .foregroundStyle(secondary)
        }
    }

    private func programmeTitle(_ title: String) -> some View {
        Text(title)
            .font(isTV ? .system(size: 25) : .subheadline)
            .foregroundStyle(programmeStyle)
            .lineLimit(1)
    }

    private var logo: some View {
        let placeholder = isTV ? Color.white.opacity(0.12) : Color.gray.opacity(0.3)
        return CachedAsyncImage(url: URL(string: stream.streamIcon ?? ""), maxPixelSize: logoSize) { phase in
            switch phase {
            case .empty:
                Rectangle().fill(placeholder).overlay { ProgressView() }
            case let .success(image):
                image.resizable().aspectRatio(contentMode: .fit)
            case .failure:
                Rectangle().fill(placeholder).overlay {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(secondary)
                }
            @unknown default:
                EmptyView()
            }
        }
        .frame(width: logoSize, height: logoSize)
        .clipShape(RoundedRectangle(cornerRadius: isTV ? 12 : 8, style: isTV ? .continuous : .circular))
    }
}

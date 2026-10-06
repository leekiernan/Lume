//
//  PlayerLoadingIndicator.swift
//  Lume
//
//  The mark's load state, centred over the video host while the engine is preparing or
//  (re)buffering. KSPlayer sits in `.preparing` / `.buffering` for ~10–20s
//  before the first frame, so the host suppresses its controls and shows this
//  instead — otherwise the idle Play button reads as "paused, press me".
//

import SwiftData
import SwiftUI

/// The mark's load state while the engine is preparing or (re)buffering. The
/// optional `title` is supplied only on the first open — where the dimmed
/// backdrop reads as "Loading <title>…" — and dropped for mid-stream stalls so
/// the spinner sits unobtrusively over the paused frame. Opening a live
/// channel, it also shows what's on it now, so a surf reads as where it's
/// going before the picture arrives.
struct PlayerLoadingIndicator: View {
    let title: String?
    private let channel: PlayableMedia?

    @Environment(\.modelContext) private var modelContext
    /// The skip indicator stands in for the spinner — see `SkipIndicatorHandoff`.
    @Environment(\.skipIndicatorShowing) private var skipIndicatorShowing
    @State private var nowShowing: String?

    init(title: String?) {
        self.title = title
        channel = nil
    }

    /// Opening `media` (nil once it has started): its title, and for a live
    /// channel the programme on air.
    init(opening media: PlayableMedia?) {
        title = media?.title
        channel = media
    }

    var body: some View {
        ZStack {
            // A light dim keeps the spinner legible over a bright first frame
            // without fully hiding the video once it starts to come through.
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: spacing) {
                LumeMark(motion: motion)
                    .frame(width: markSize, height: markSize)
                    .accessibilityLabel(Text("Loading…"))

                if let title, !title.isEmpty {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 40)
                        .shadow(radius: 8)
                }
                if title != nil, let nowShowing {
                    Text(nowShowing)
                        .font(nowShowingFont)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .padding(.horizontal, 40)
                        .shadow(radius: 8)
                        .transition(.opacity)
                }
            }
        }
        .opacity(skipIndicatorShowing ? 0 : 1)
        .allowsHitTesting(false)
        .task(id: channel?.id) {
            // Cleared first: a second surf must not show the last channel's
            // programme under the new channel's name.
            nowShowing = nil
            nowShowing = await Self.programmeOnAir(for: channel, in: modelContext)
        }
    }

    /// Opening a live channel is "going live" (Emit); anything else — a
    /// first open of a title, or a mid-stream stall — is buffering (Pulse).
    private var motion: LumeMark.Motion {
        if title != nil, let channel, case .live = channel.kind { return .emit }
        return .pulse
    }

    /// The programme on air on a live channel, from the guide, off the main
    /// thread. Nil for anything but a live channel, or with no guide data.
    private static func programmeOnAir(for media: PlayableMedia?, in context: ModelContext) async -> String? {
        guard let media, case .live = media.kind, case let .live(id) = media.contentRef,
              let channelId = PlayerContentLookup.liveStream(id, in: context)?.epgChannelId
        else { return nil }
        let container = context.container
        let now = Date()
        let epg = await Task.detached(priority: .userInitiated) {
            ChannelEPGLoader.load(container: container, channelIds: [channelId], now: now)
        }.value
        return epg[channelId]?.current?.title
    }

    #if os(tvOS)
        private var spacing: CGFloat {
            36
        }

        private var markSize: CGFloat {
            180
        }

        private var titleFont: Font {
            .system(size: 40, weight: .semibold)
        }

        private var nowShowingFont: Font {
            .system(size: 28, weight: .regular)
        }
    #else
        private var spacing: CGFloat {
            20
        }

        private var markSize: CGFloat {
            72
        }

        private var titleFont: Font {
            .title3.weight(.semibold)
        }

        private var nowShowingFont: Font {
            .callout
        }
    #endif
}

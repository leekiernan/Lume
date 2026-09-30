import SwiftUI

/// The tvOS end-of-episode Next Episode button. `EpisodeOverlayMachine` decides
/// when it shows — from the outro arm point `OutroTrigger` computes, which is
/// never earlier than the 90% watched line — and runs auto-advance on every
/// platform; this draws the button, with a bar that drains from the arm point
/// to the end of the episode.
///
/// Other platforms never show it: they carry an always-available Next Episode
/// button in the transport row (`PlayerItemNavButton`).
struct PlayerNextUpOverlay: View {
    let nextMedia: PlayableMedia
    /// Read only by `NextEpisodeCountdown`, so the per-tick re-render stays in
    /// that leaf.
    let clock: PlaybackClock
    let outro: IntroSegments.Segment?
    let onPlayNext: () -> Void

    var body: some View {
        #if os(tvOS)
            Button(action: onPlayNext) {
                HStack(spacing: 18) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next Episode")
                            .font(.system(size: 24, weight: .semibold))
                        if let subtitle = nextMedia.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 19))
                                .opacity(0.7)
                                .lineLimit(1)
                        }
                        NextEpisodeCountdown(clock: clock, outro: outro)
                            .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 26)
            }
            .buttonStyle(TVGlassButtonStyle())
            .frame(width: 460)
            .padding(.trailing, 80)
            .padding(.bottom, 60)
        #else
            // Never offered off tvOS (`EpisodeOverlayMachine.Config.nextButton`).
            EmptyView()
        #endif
    }
}

/// How much of the episode is left after the Next Episode button armed: full
/// when it appears, empty at the end. Driven by the playback clock rather than
/// a timer, so it holds still while paused and jumps with a seek.
private struct NextEpisodeCountdown: View {
    let clock: PlaybackClock
    let outro: IntroSegments.Segment?

    var body: some View {
        ProgressView(value: remaining)
            .progressViewStyle(.linear)
            .tint(.white)
    }

    private var remaining: Double {
        let duration = clock.duration
        guard let armTime = OutroTrigger.armTime(outro: outro, duration: duration), duration > armTime else { return 0 }
        return min(max((duration - clock.current) / (duration - armTime), 0), 1)
    }
}

import SwiftUI

/// The "Skip Intro" / "Skip Recap" button. When it shows, and what pressing or
/// dismissing it does, is `EpisodeOverlayMachine`'s call via
/// `PlayerEpisodeOverlays`; this only draws it.
///
/// There is deliberately no "Skip Outro" button: end credits stay with the
/// Next Episode button and auto-advance, so the two never overlap. IntroDB's
/// outro window still sets when Next Episode arms (`OutroTrigger`).
struct PlayerSkipIntroOverlay: View {
    let label: LocalizedStringKey
    let remote: EpisodeButtonRemote
    let onSkip: () -> Void

    var body: some View {
        #if os(tvOS)
            // Matches `PlayerNextUpOverlay`'s tvOS button verbatim (glass style,
            // 26pt leading glyph, trailing Spacer + fixed 460pt width) so the two
            // in-player affordances are visually identical.
            Button(action: onSkip) {
                HStack(spacing: 18) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 26, weight: .semibold))
                    Text(label)
                        .font(.system(size: 24, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 26)
            }
            .buttonStyle(TVGlassButtonStyle())
            .episodeButtonRemote(remote)
            .frame(width: 460)
            .padding(.trailing, 80)
            .padding(.bottom, 60)
        #else
            Button(action: onSkip) {
                HStack(spacing: 8) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .contentShape(Capsule())
                .glassEffectCompat(.regularInteractive, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 40)
        #endif
    }
}

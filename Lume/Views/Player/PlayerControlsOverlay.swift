import SwiftData
import SwiftUI

/// A low-frequency snapshot: clocks, native subtitle text and decoder state
/// stay outside this presentation boundary. Engine adapters retain observation
/// and seek semantics; this view owns only matching layout/menu presentation.
struct PlayerControlsPresentation {
    let engine: PlayerEngineKind
    let isPlaying: Bool
    let videoInfo: PlayerVideoInfo?
    let audioTracks: [PlayerTrackOption]
    let textTracks: [PlayerTrackOption]
    let rate: Float
    let isPipSupported: Bool
    let isPipActive: Bool
    /// nil means this engine has no fit/fill control.
    var isAspectFill: Bool?

    var showsAudioMenu: Bool {
        audioTracks.count > 1
    }

    func showsSubtitleMenu(searchAvailable: Bool) -> Bool {
        !textTracks.isEmpty || searchAvailable
    }
}

struct PlayerControlsActions {
    let close: () -> Void
    let togglePlay: () -> Void
    let togglePip: () -> Void
    let resetHideTimer: () -> Void
    let skip: (TimeInterval) -> Void
    let selectAudioTrack: (String) -> Void
    let selectTextTrack: (String?) -> Void
    let setRate: (Float) -> Void
    let sliderEditingChanged: (Bool) -> Void
    var toggleAspectFill: (() -> Void)?
    var searchSubtitles: (() -> Void)?
    var stepItem: ((PlayerMediaSwapper.Step) -> Void)?
}

#if !os(tvOS)
    struct PlayerControlsOverlay<Route: View>: View {
        let presentation: PlayerControlsPresentation
        let actions: PlayerControlsActions
        let media: PlayableMedia
        @Binding var isSeeking: Bool
        @Binding var seekPosition: TimeInterval
        /// Only PlaybackTimeline reads this clock; menus never observe ticks.
        let clock: PlaybackClock
        let route: Route
        var itemNeighbours = PlayerItemNavigation.Neighbours.none

        @Environment(\.modelContext) private var modelContext
        private var isFavorite: Bool {
            PlayerFavorites.isFavorite(for: media.contentRef, in: modelContext)
        }

        var body: some View {
            ZStack {
                scrim

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    centerTransport
                    Spacer(minLength: 0)
                    bottomControls
                }
            }
        }

        // MARK: - Scrim

        /// Subtle top/bottom darkening so the white glyphs and title stay legible
        /// over bright video. The glass controls carry their own legibility; this
        /// only protects the bare text.
        private var scrim: some View {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.28),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.55), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }

        // MARK: - Top Bar

        private var topBar: some View {
            HStack {
                Button(action: actions.close) {
                    circleGlyph("xmark", size: 15, diameter: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close player")
                .keyboardShortcut(.escape, modifiers: [])

                pipButton

                #if os(macOS)
                    MacPlayerFullScreenButton()
                #endif

                Spacer()

                route
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }

        @ViewBuilder
        private var pipButton: some View {
            if presentation.isPipSupported {
                Button {
                    actions.togglePip()
                    actions.resetHideTimer()
                } label: {
                    circleGlyph(presentation.isPipActive ? "pip.exit" : "pip.enter", size: 16, diameter: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(presentation.isPipActive ? "Exit Picture in Picture" : "Picture in Picture")
            }
        }

        // MARK: - Center Transport

        /// The episode pair turns this into a five-circle row, which is wider
        /// than a phone in portrait at the spacing the three-button row used.
        /// Close the gaps rather than let the outer buttons clip off-screen.
        private var centerTransport: some View {
            ViewThatFits(in: .horizontal) {
                transportRow(spacing: 32)
                transportRow(spacing: 12)
            }
        }

        /// ∓15 s, or a drop-in minute on catch-up.
        private var skipStep: PlayerSkipStep {
            PlayerSkipStep(seconds: media.skipInterval(default: 15))
        }

        private func transportRow(spacing: CGFloat) -> some View {
            HStack(spacing: spacing) {
                if itemNeighbours.axis != nil {
                    PlayerItemNavButton(
                        step: .previous,
                        neighbours: itemNeighbours,
                        onStep: { actions.stepItem?($0) },
                        onResetHideTimer: actions.resetHideTimer
                    )
                }

                if !media.isLive {
                    Button {
                        actions.skip(-skipStep.seconds)
                        actions.resetHideTimer()
                    } label: {
                        circleGlyph(skipStep.backSymbol, size: 22, diameter: 60)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(skipStep.backLabel)
                }

                Button(action: actions.togglePlay) {
                    circleGlyph(
                        presentation.isPlaying ? "pause.fill" : "play.fill",
                        size: 30,
                        diameter: 76
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(presentation.isPlaying ? "Pause" : "Play")

                if !media.isLive {
                    Button {
                        actions.skip(skipStep.seconds)
                        actions.resetHideTimer()
                    } label: {
                        circleGlyph(skipStep.forwardSymbol, size: 22, diameter: 60)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(skipStep.forwardLabel)
                }

                if itemNeighbours.axis != nil {
                    PlayerItemNavButton(
                        step: .next,
                        neighbours: itemNeighbours,
                        onStep: { actions.stepItem?($0) },
                        onResetHideTimer: actions.resetHideTimer
                    )
                }
            }
        }

        // MARK: - Bottom Controls

        private var bottomControls: some View {
            VStack(spacing: 14) {
                HStack(alignment: .bottom, spacing: 16) {
                    titleBlock
                    Spacer(minLength: 0)
                    secondaryControls
                }

                if media.isLive {
                    liveIndicator
                } else {
                    PlaybackTimeline(
                        clock: clock,
                        isSeeking: $isSeeking,
                        seekPosition: $seekPosition,
                        onEditingChanged: actions.sliderEditingChanged
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .reportsControlsHeight()
        }

        private var titleBlock: some View {
            VStack(alignment: .leading, spacing: 2) {
                StreamInfoCaption(
                    media: media,
                    videoInfo: presentation.videoInfo,
                    engine: presentation.engine
                )
                if let subtitle = media.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Text(media.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }

        private var liveIndicator: some View {
            HStack(spacing: 7) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text("LIVE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }

        // MARK: - Secondary Controls (grouped glass pill)

        private var secondaryControls: some View {
            HStack(spacing: 4) {
                if presentation.showsSubtitleMenu(searchAvailable: actions.searchSubtitles != nil) {
                    subtitleMenu
                }
                if presentation.showsAudioMenu {
                    audioTrackMenu
                }
                if !media.isLive {
                    playbackRateMenu
                }
                if presentation.isAspectFill != nil { contentModeButton }
                favoriteButton
            }
            .padding(.horizontal, 4)
            .glassEffectCompat(.regularInteractive, in: Capsule())
        }

        private var favoriteButton: some View {
            Button {
                PlayerFavorites.requestToggle(for: media.contentRef, in: modelContext)
                actions.resetHideTimer()
            } label: {
                MediaFavoriteGlyph(isFavorite: isFavorite, showTrackers: !media.isLive)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "In Favorites" : "Favorite")
        }

        @ViewBuilder
        private var subtitleMenu: some View {
            let tracks = presentation.textTracks
            let hasSelection = tracks.contains(where: \.isSelected)
            Menu {
                Button {
                    actions.selectTextTrack(nil)
                    actions.resetHideTimer()
                } label: {
                    playerCheckmarkLabel("Off", checked: !hasSelection)
                }
                ForEach(tracks) { track in
                    Button {
                        actions.selectTextTrack(track.id)
                        actions.resetHideTimer()
                    } label: {
                        playerCheckmarkLabel(verbatim: track.label, checked: track.isSelected)
                    }
                }
                if let search = actions.searchSubtitles {
                    Divider()
                    Button {
                        search()
                        actions.resetHideTimer()
                    } label: {
                        Label("Search Online…", systemImage: "magnifyingglass")
                    }
                }
            } label: {
                pillGlyph("captions.bubble.fill", dimmed: !hasSelection)
            }
            .menuIndicator(.hidden)
            .trackMenuAccessibility("Subtitles", selected: tracks.first(where: \.isSelected)?.label, fallback: "Off")
        }

        @ViewBuilder
        private var audioTrackMenu: some View {
            let tracks = presentation.audioTracks
            Menu {
                ForEach(tracks) { track in
                    Button {
                        actions.selectAudioTrack(track.id)
                        actions.resetHideTimer()
                    } label: {
                        playerCheckmarkLabel(verbatim: track.label, checked: track.isSelected)
                    }
                }
            } label: {
                pillGlyph("waveform")
            }
            .menuIndicator(.hidden)
            .trackMenuAccessibility("Audio Track", selected: tracks.first(where: \.isSelected)?.label, fallback: "Default")
        }

        private var playbackRateMenu: some View {
            Menu {
                ForEach([0.5, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { rate in
                    Button {
                        actions.setRate(rate)
                        actions.resetHideTimer()
                    } label: {
                        playerCheckmarkLabel(verbatim: rateString(rate), checked: abs(presentation.rate - rate) < 0.01)
                    }
                }
            } label: {
                Text(verbatim: rateString(presentation.rate))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
        }

        private var contentModeButton: some View {
            Button {
                actions.toggleAspectFill?()
                actions.resetHideTimer()
            } label: {
                pillGlyph(presentation.isAspectFill == true ? "rectangle.fill" : "rectangle.arrowtriangle.2.inward")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.isAspectFill == true ? "Fit video" : "Fill screen")
        }

        // MARK: - Building Blocks

        /// A white glyph centered in an interactive Liquid Glass circle — the
        /// shared shape for every standalone control (close, PiP, transport).
        private func circleGlyph(
            _ systemName: String,
            size: CGFloat,
            diameter: CGFloat,
            dimmed: Bool = false
        ) -> some View {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(dimmed ? .white.opacity(0.55) : .white)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .glassEffectCompat(.regularInteractive, in: Circle())
        }

        /// A white glyph sized for the grouped track pill. Carries no glass of
        /// its own — the enclosing capsule is the single glass surface.
        private func pillGlyph(_ systemName: String, dimmed: Bool = false) -> some View {
            Image(systemName: systemName)
                // Covers every toggling glyph in the bar — play/pause, mute, heart.
                .symbolReplaceTransition(value: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(dimmed ? .white.opacity(0.55) : .white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }

        /// Compact rate label, e.g. `1×`, `1.25×`. `%g` drops trailing zeros.
        private func rateString(_ rate: Float) -> String {
            String(format: "%g×", rate)
        }
    }
#endif

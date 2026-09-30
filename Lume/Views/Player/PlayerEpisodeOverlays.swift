import OSLog
import SwiftUI

/// The episode affordances every engine host layers above its own controls:
/// Skip Intro / Skip Recap, the tvOS Next Episode button and auto-advance.
/// One IntroDB lookup drives them all, and one `EpisodeOverlayMachine` decides
/// which is showing — the buttons below only draw what it offers.
///
/// The engines differ only in how they seek and what they hand focus back to
/// afterwards, so that comes in as a closure.
struct PlayerEpisodeOverlays: View {
    /// Intro / recap / outro windows for the active episode (from IntroDB);
    /// `nil` when IntroDB knows nothing about it.
    let segments: IntroSegments?
    /// The episode queued after the current one; `nil` when there is nothing to
    /// play next.
    let nextUpMedia: PlayableMedia?
    /// The shared playback clock. Only `EpisodeZoneReporter` reads it, so a
    /// tick re-renders that leaf and nothing here.
    let clock: PlaybackClock
    /// Whether the engine's own controls overlay is currently showing.
    let controlsVisible: Bool
    /// Seeks the underlying player to an absolute time, in seconds.
    let onSeek: (TimeInterval) -> Void
    let onSelectMedia: (PlayableMedia) -> Void

    @State private var machine = EpisodeOverlayMachine()

    @AppStorage(PlayerSettings.Playback.showSkipIntroButtonKey)
    private var showSkipIntroButton = PlayerSettings.Playback.showSkipIntroButtonDefault
    @AppStorage(PlayerSettings.Playback.showNextEpisodeButtonKey)
    private var showNextButton = PlayerSettings.Playback.showNextEpisodeButtonDefault
    @AppStorage(PlayerSettings.Playback.autoPlayNextKey)
    private var autoPlayNext = PlayerSettings.Playback.autoPlayNextDefault
    /// Next Episode and auto-advance are Premium; free users get neither,
    /// whatever the stored toggles say.
    @State private var premium = PremiumManager.shared

    #if os(tvOS)
        @FocusState private var buttonFocused: Bool
    #endif

    var body: some View {
        ZStack {
            EpisodeZoneReporter(clock: clock, segments: segments) { send(.zone($0)) }

            if let offer = machine.visibleOffer {
                button(for: offer)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(machine.visibleOffer != nil)
        .animation(.easeInOut(duration: 0.25), value: machine.visibleOffer)
        .onChange(of: config, initial: true) { _, config in send(.configure(config)) }
        .onChange(of: controlsVisible, initial: true) { _, visible in send(.controls(visible: visible)) }
        .onChange(of: episodeKey) { _, _ in send(.reset) }
        #if os(tvOS)
            .onChange(of: machine.visibleOffer) { _, offer in
                // Pull focus onto the button the moment it appears, so one
                // Select acts on it.
                if offer != nil { Task { @MainActor in buttonFocused = true } }
            }
        #endif
    }

    private var config: EpisodeOverlayMachine.Config {
        #if os(tvOS)
            let nextButton = premium.isPremium && showNextButton
        #else
            // iOS / macOS / visionOS carry an always-available Next Episode
            // button in the transport row (`PlayerItemNavButton`); an
            // outro-armed second one would compete with it.
            let nextButton = false
        #endif
        return EpisodeOverlayMachine.Config(
            skipButton: showSkipIntroButton,
            nextButton: nextButton,
            autoAdvance: premium.isPremium && autoPlayNext,
            hasNextEpisode: nextUpMedia != nil
        )
    }

    /// Changes when a different episode's data arrives: its segments, or what
    /// follows it.
    private var episodeKey: EpisodeKey {
        EpisodeKey(segments: segments, nextID: nextUpMedia?.id)
    }

    private struct EpisodeKey: Equatable {
        let segments: IntroSegments?
        let nextID: String?
    }

    private func send(_ event: EpisodeOverlayMachine.Event) {
        let before = machine.state
        let effects = machine.handle(event)
        if machine.state != before {
            // Read here, not in `body`, so the journal line records no clock
            // dependency.
            let playhead = Int(clock.current)
            Logger.player.info("overlays: \(before.logName) → \(machine.state.logName) at \(playhead) s")
        }
        for effect in effects {
            switch effect {
            case let .seek(time):
                onSeek(time)
            case .playNext:
                if let nextUpMedia { onSelectMedia(nextUpMedia) }
            }
        }
    }

    @ViewBuilder
    private func button(for offer: EpisodeOverlayMachine.Offer) -> some View {
        Group {
            switch offer {
            case .skipRecap:
                PlayerSkipIntroOverlay(label: "Skip Recap") { send(.activate) }
            case .skipIntro:
                PlayerSkipIntroOverlay(label: "Skip Intro") { send(.activate) }
            case .nextEpisode:
                if let nextUpMedia {
                    PlayerNextUpOverlay(nextMedia: nextUpMedia) { send(.activate) }
                }
            }
        }
        #if os(tvOS)
        .focused($buttonFocused)
        // Menu on the button dismisses it (focus falls back to the player)
        // rather than closing the player outright.
        .onExitCommand { send(.dismiss) }
        #endif
    }
}

/// Reads the ten-a-second `PlaybackClock` and reports only a change of
/// `EpisodeOverlayMachine.Zone` — a window boundary crossed by playback or
/// jumped by a seek. A leaf of its own, so the per-tick re-render stops here.
private struct EpisodeZoneReporter: View {
    let clock: PlaybackClock
    let segments: IntroSegments?
    let onChange: (EpisodeOverlayMachine.Zone) -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: zone, initial: true) { _, zone in onChange(zone) }
    }

    private var zone: EpisodeOverlayMachine.Zone {
        EpisodeOverlayMachine.zone(current: clock.current, duration: clock.duration, segments: segments)
    }
}

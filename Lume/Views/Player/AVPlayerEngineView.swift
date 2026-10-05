import AVFoundation
import SwiftData
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// AVPlayer-backed video host with custom Apple-style controls.
///
/// This used to wrap `AVPlayerViewController` and lean on AVKit's built-in
/// transport. To match the VLCKit and KSPlayer engines — which both draw their
/// own auto-hiding overlay — it now renders straight into an `AVPlayerLayer`
/// (`AVPlayerVideoContainer`) and layers the very same controls on top: the
/// shared `TVPlayerControlsOverlay` on tvOS, and `AVPlayerControlsOverlay` on
/// iOS / macOS. State (`AVPlayerCoordinator`), the tap-catcher, the auto-hide
/// timer and live-channel surfing all mirror `VLCPlayerEngineView`.
struct AVPlayerEngineView: View {
    let media: PlayableMedia
    /// High-frequency playback clock, held as the `@Observable` object rather
    /// than as `@Binding` scalars — see `VLCPlayerEngineView` for why this keeps
    /// the engine view off the per-tick re-render path.
    @Bindable var clock: PlaybackClock
    /// The host's stream-change serialiser (`FullScreenPlayerView.mediaSwapper`):
    /// the Siri remote's channel surfing and the on-screen transport controls
    /// share it, so two swaps can never be in flight at once.
    let mediaSwapper: PlayerMediaSwapper
    /// The episode queued after `media`, resolved by the host. Drives the
    /// end-of-episode Next Up affordances; `nil` when there is nothing to play
    /// next.
    var nextUpMedia: PlayableMedia?
    /// Previous/next stream for the transport controls, resolved once per stream
    /// by the host: the surrounding episodes of a series, or the channels either
    /// side of a live one. `neighboursUnknown` means the catalog has no episode
    /// rows yet, which the controls render as disabled rather than absent.
    var itemNeighbours = PlayerItemNavigation.Neighbours.none
    /// Intro / recap / outro windows for the active episode (from IntroDB). The
    /// openers drive the in-player Skip Intro button; the outro sets when the
    /// Next Episode button arms. `nil` when IntroDB knows nothing about it.
    var skipSegments: IntroSegments?
    /// When true, an initial-load failure reports to the host via
    /// `onPlaybackFailed` (which decides what to try next — another engine, or
    /// reverting an AirPlay override) instead of raising this engine's own
    /// error overlay.
    var reportsStartupFailure = false
    /// Use the shorter fallback startup window before declaring failure, so a
    /// switch to the next engine is prompt. Off for attempts that should wait
    /// out the full startup timeout (last resort, or an AirPlay cast attempt).
    var usesQuickStartupTimeout = false
    /// Invoked on an initial-load failure when `reportsStartupFailure` is set.
    var onPlaybackFailed: (() -> Void)?
    /// Invoked when the viewer picks a different stream (another episode, or a
    /// live channel via the Siri remote) from the in-player overlay.
    var onSelectMedia: ((PlayableMedia) -> Void)?
    /// Invoked when an explicit "next episode" press leaves the current episode
    /// behind, so the host can mark it watched and scrobble it. The press is
    /// available from the first frame, below the completion line the automatic
    /// advance relies on, so it has to say so itself.
    var onCompleteCurrentItem: (() -> Void)?
    /// What the lock screen's next/previous track buttons play, owned by the
    /// host and handed to `NowPlayingService` with this engine's transport.
    /// `nil` on tvOS, where the Siri Remote already owns stream changes.
    var onRemoteAdvance: ((PlayerMediaSwapper.Step) -> Bool)?
    /// Takes every seek and skip on a catch-up programme — see `CatchupSeekRouter`.
    var onCatchupSeek: ((CatchupSeek) -> Void)?
    /// The full-screen session this engine reports to; nil in Multi-View.
    var session: PlaybackSession?

    @StateObject var coordinator = AVPlayerCoordinator()
    @State private var chrome = PlayerChromeController()
    private var isControlsVisible: Bool {
        chrome.isVisible
    }

    @Environment(PlayerControlsBridge.self) private var remoteBridge: PlayerControlsBridge?
    /// Set once the stream is given up on (initial-load failure with no fallback
    /// left). Swaps the player for the `PlayerErrorIndicator` (Try Again / Back).
    @State var loadFailed = false
    @State private var isCatchupSegmentLoading = false
    @State private var isSeeking = false
    @State private var seekPosition: TimeInterval = 0
    /// While an overlay panel (episodes / info) is open the controls must not
    /// auto-hide out from under the viewer.
    @State private var isPanelOpen = false
    /// Bumped to ask the overlay to close its open panel (Menu/back press).
    @State private var panelCloseToken = 0
    #if os(tvOS)
        /// The full channel browser (categories + channels) raised by a left
        /// press while watching live TV with the controls hidden.
        @State private var isChannelBrowserOpen = false
        /// Drives focus onto the transparent tap-catcher once the controls
        /// auto-hide, so the Siri remote can summon them again.
        @FocusState private var catcherFocused: Bool
        @Environment(\.modelContext) private var modelContext
        /// Keeps channel surfing inside what this viewer may watch — a child
        /// profile must not be able to rock up/down, or recall the last channel,
        /// into a category a parent locked or the user hid.
        @Environment(\.contentRestriction) private var restriction
    #endif

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var drawsControls: Bool {
        PlayerChrome.drawsControls(requested: isControlsVisible, started: coordinator.hasStartedPlayback, catchupSegmentLoading: isCatchupSegmentLoading, failed: loadFailed)
    }

    var engineBody: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            AVPlayerVideoContainer(coordinator: coordinator)
                .ignoresSafeArea()

            // Always-present transparent layer that reliably catches taps over
            // the player surface, mirroring the VLCKit/KSPlayer hosts. Full
            // bleed: the host keeps the overlays inside the safe area on iOS,
            // but a tap at the very edges should still summon the controls.
            tapCatcher
                .ignoresSafeArea()

            if drawsControls {
                controlsOverlay
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            PlayerEpisodeOverlays(
                segments: skipSegments,
                nextUpMedia: nextUpMedia,
                clock: clock,
                controlsVisible: isControlsVisible,
                onSeek: { time in
                    coordinator.seek(to: time)
                    #if os(tvOS)
                        // The skip button held focus; hand it back to the
                        // tap-catcher so the remote keeps working.
                        Task { @MainActor in catcherFocused = true }
                    #endif
                },
                onSelectMedia: { onSelectMedia?($0) }
            )

            #if os(tvOS)
                if isChannelBrowserOpen {
                    channelBrowser
                }
            #endif

            if coordinator.isBuffering, !loadFailed {
                PlayerLoadingIndicator(opening: coordinator.hasStartedPlayback || isCatchupSegmentLoading ? nil : media)
                    .transition(.opacity)
            }

            if loadFailed {
                PlayerErrorIndicator(
                    title: media.title,
                    onRetry: { retryPlayback() },
                    onClose: { closePlayer() }
                )
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            chrome.activate()
            let catchup = coordinator.catchup
            coordinator.onTime = { current in
                if !isSeeking { catchup.report(position: current, to: clock) }
            }
            coordinator.onDuration = { catchup.report(duration: $0, to: clock) }
            catchup.onSeek = onCatchupSeek
            coordinator.onPlaybackFailure = { reportFailure() }
            coordinator.startupTimeout = PlaybackPolicy.startupTimeout(quick: usesQuickStartupTimeout)
            coordinator.retriesStartupErrors = PlaybackPolicy.retriesStartupError(canFallBack: reportsStartupFailure)
            coordinator.configure(media: media)
            NowPlayingService.shared.attachTransport(
                .driving(coordinator, advance: onRemoteAdvance), owner: coordinator
            )
            scheduleHide()
        }
        .onDisappear {
            chrome.deactivate()
            NowPlayingService.shared.detachTransport(owner: coordinator)
            coordinator.tearDown()
        }
        .onChange(of: coordinator.isPlaying) { _, playing in
            clock.isPlaying = playing
            scheduleHide()
        }
        .onChange(of: coordinator.hasStartedPlayback) { _, started in
            if started { isCatchupSegmentLoading = false }
        }
        .onChange(of: scenePhase) { _, phase in
            // The Home button backgrounds the app without calling onDisappear,
            // so pause here to stop audio when the player loses focus.
            if phase != .active { coordinator.pauseForBackground() }
        }
        .onChange(of: media) { oldMedia, newMedia in
            // The host swapped the stream (e.g. a new episode). Reset local
            // scrubbing state and hand the new media to the live player.
            isSeeking = false
            seekPosition = 0
            isPanelOpen = false
            loadFailed = false
            isCatchupSegmentLoading = PlayerChrome.keepsCatchupControls(
                previous: oldMedia.catchup, next: newMedia.catchup,
                started: coordinator.hasStartedPlayback, alreadyLoading: isCatchupSegmentLoading
            )
            coordinator.reload(media: newMedia)
            scheduleHide()
        }
        #if os(tvOS)
        // Focus returns to the tap-catcher as the controls vanish, unless an
        // episode button is up to take it.
        .episodeButtonFocusHandoff(
            controlsVisible: isControlsVisible, catcherFocused: $catcherFocused, showControls: showControls
        )
        #endif
        .playerRemoteControls(controlsVisible: isControlsVisible, onBack: handleMenuPress, onPlayPause: togglePlay)
        #if os(macOS)
            .playerPointerChrome(chrome, mayHide: { canAutoHideControls })
            .onKeyPress(.leftArrow) { coordinator.skip(by: -media.skipInterval(default: 15)); scheduleHide(); return .handled }
            .onKeyPress(.rightArrow) { coordinator.skip(by: media.skipInterval(default: 15)); scheduleHide(); return .handled }
            .liveChannelKeyNavigation(
                neighbours: itemNeighbours, swapper: mediaSwapper,
                onSelect: { onSelectMedia?($0) }, onResetHideTimer: scheduleHide
            )
            .onKeyPress(.space) { togglePlay(); return .handled }
            .onKeyPress(.escape) { closePlayer(); return .handled }
        #endif
    }

    // MARK: - Tap Catcher

    @ViewBuilder
    private var tapCatcher: some View {
        #if os(tvOS)
            PlayerTapCatcher(
                isLive: media.isLive, controlsDrawn: drawsControls,
                browserOpen: isChannelBrowserOpen, failed: loadFailed,
                focused: $catcherFocused, showControls: showControls,
                openBrowser: openChannelBrowser, surf: switchLiveChannel
            )
        #else
            PlayerTapCatcher(toggleControls: toggleControls)
        #endif
    }

    // MARK: - Controls Overlay

    @ViewBuilder
    private var controlsOverlay: some View {
        #if os(tvOS)
            TVPlayerControlsOverlay(
                coordinator: coordinator,
                media: media,
                clock: clock,
                panelCloseToken: panelCloseToken,
                onTogglePlay: { togglePlay() },
                onResetHideTimer: { scheduleHide() },
                onSelectMedia: { onSelectMedia?($0) },
                onPanelOpenChange: { setPanelOpen($0) },
                onSwitchChannel: { switchLiveChannel($0) },
                mediaSwapper: mediaSwapper, onCompleteCurrentItem: { onCompleteCurrentItem?() }
            )
        #else
            AVPlayerControlsOverlay(
                coordinator: coordinator,
                media: media,
                isSeeking: $isSeeking,
                seekPosition: $seekPosition,
                clock: clock,
                onSuspendHide: { chrome.suspend() },
                onClose: { closePlayer() },
                onTogglePlay: { togglePlay() },
                onResetHideTimer: { scheduleHide() },
                onScheduleHide: { scheduleHide() },
                itemNeighbours: itemNeighbours,
                onStepItem: { stepItem($0) }
            )
        #endif
    }

    // MARK: - Actions

    private func togglePlay() {
        coordinator.togglePlay()
        scheduleHide()
    }

    #if os(tvOS)
        /// Change the live channel from the Siri Remote — up/down surf to the
        /// adjacent channel, right recalls the channel watched just before this
        /// one. Falls back to summoning the controls when there's nothing to
        /// jump to.
        private func switchLiveChannel(_ direction: MoveCommandDirection) {
            mediaSwapper.surf(
                direction, from: media,
                through: .init(
                    restriction: restriction, context: modelContext,
                    neighbours: itemNeighbours
                ),
                select: { onSelectMedia?($0) },
                showControls: showControls
            )
        }

        /// The two-column category / channel browser, slid in over the leading
        /// edge. Picking a channel switches the stream and surfaces the controls
        /// briefly so the new channel's name and EPG act as a banner.
        private var channelBrowser: some View {
            TVPlayerChannelBrowser(
                media: media, isPresented: $isChannelBrowserOpen, chrome: chrome,
                mayHide: { canAutoHideControls }, onSelect: { onSelectMedia?($0) },
                onClose: { closeChannelBrowser() }
            )
        }

        private func openChannelBrowser() {
            chrome.openBrowser(isLive: media.isLive, isPresented: $isChannelBrowserOpen)
        }

        private func closeChannelBrowser() {
            chrome.closeBrowser(isPresented: $isChannelBrowserOpen, mayHide: { canAutoHideControls })
            // Hand focus back to the tap-catcher so the remote keeps working.
            Task { @MainActor in catcherFocused = true }
        }
    #endif

    private func toggleControls() {
        chrome.toggle(mayHide: { canAutoHideControls })
    }

    private func showControls() {
        chrome.show(mayHide: { canAutoHideControls })
    }

    /// Menu/back routing: close the channel browser or an open panel first,
    /// then hide the controls, and only dismiss the player once the controls
    /// are already hidden.
    private func handleMenuPress() {
        #if os(tvOS)
            let browserOpen = isChannelBrowserOpen
            let closeBrowser = closeChannelBrowser
        #else
            let browserOpen = false
            let closeBrowser = {}
        #endif
        chrome.menu(
            .init(failed: loadFailed, browserOpen: browserOpen, panelOpen: isPanelOpen),
            claimsBack: { remoteBridge?.claimsBack() == true }, closeBrowser: closeBrowser,
            closePanel: { panelCloseToken += 1 }, closePlayer: closePlayer
        )
    }

    /// Keep the controls pinned open while an overlay panel is showing.
    private func setPanelOpen(_ open: Bool) {
        isPanelOpen = open
        chrome.panelChanged(isOpen: open, mayHide: { canAutoHideControls })
    }

    private var canAutoHideControls: Bool {
        #if os(tvOS)
            let browserOpen = isChannelBrowserOpen
        #else
            let browserOpen = false
        #endif
        return PlayerControlsAutoHide.mayHide(
            isPlaying: coordinator.isPlaying,
            isPanelOpen: isPanelOpen || browserOpen || isSeeking,
            isSuppressed: PlayerControlsAutoHide.isSuppressed
        )
    }

    private func scheduleHide() {
        chrome.schedule(mayHide: { canAutoHideControls })
    }

    private func closePlayer() {
        #if os(macOS)
            MacPlayerWindowRouter.shared.close()
        #else
            dismiss()
        #endif
    }

    /// The coordinator reported it can't start the stream. On an initial-load
    /// failure with a fallback engine available, hand off to the host (which
    /// switches engines); otherwise raise the failure overlay.
    private func reportFailure() {
        guard !loadFailed else { return }
        isCatchupSegmentLoading = false
        if reportsStartupFailure, !coordinator.hasStartedPlayback {
            onPlaybackFailed?()
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) { loadFailed = true }
    }

    /// Re-prepare the current stream after a failure (the Try Again button).
    private func retryPlayback() {
        isCatchupSegmentLoading = false
        withAnimation(.easeInOut(duration: 0.25)) { loadFailed = false }
        coordinator.retryAfterFailure()
    }
}

#Preview {
    AVPlayerEngineView(
        media: PlayableMedia(
            id: "preview",
            url: URL(string: "https://example.com/stream.m3u8")!,
            title: "Sample Video",
            subtitle: nil,
            posterURL: nil,
            kind: .vod,
            startTime: 0,
            contentRef: .movie("preview")
        ),
        clock: PlaybackClock(),
        mediaSwapper: PlayerMediaSwapper()
    )
    .preferredColorScheme(.dark)
}

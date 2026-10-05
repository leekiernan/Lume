import AVFoundation
import Combine
import KSPlayer
import SwiftUI

// Engine observation and scrubbing adapter for the shared standard overlay.
#if !os(tvOS)
    struct KSPlayerControlsOverlay: View {
        @ObservedObject var coordinator: KSVideoPlayer.Coordinator
        let media: PlayableMedia
        @Binding var isPlaying: Bool
        @Binding var isSeeking: Bool
        @Binding var seekPosition: TimeInterval
        /// The 10 Hz playback clock. Deliberately the `@Observable` object, not
        /// `$clock.current` bindings: reading a tick-driven value in this body
        /// would re-render the whole overlay — and an open `Menu` whose host
        /// keeps re-rendering flickers its items and cancels in-flight taps
        /// (the audio/subtitle pickers were near-unusable). Only the
        /// `PlaybackTimeline` leaf reads the clock; this body must never.
        let clock: PlaybackClock
        @Binding var isPipActive: Bool
        var onSuspendHide: () -> Void
        var onClose: () -> Void
        var onTogglePlay: () -> Void
        var onTogglePip: () -> Void
        var onResetHideTimer: () -> Void
        var onScheduleHide: () -> Void
        /// Seek / skip through the engine view, which hands a catch-up
        /// programme's seeks to the host (`KSPlayerEngineView+Catchup`).
        var onSeek: (TimeInterval) -> Void
        var onSkip: (TimeInterval) -> Void
        /// Raises the OpenSubtitles browser. `nil` when the search isn't
        /// available for this stream, which also drops the menu entry.
        var onSearchSubtitles: (() -> Void)?
        /// Video-track snapshot for the Advanced stream-info caption. `nil`
        /// until the first frame reports usable dimensions.
        var videoInfo: PlayerVideoInfo?
        /// Previous/next stream for the transport pair, resolved once per stream
        /// by the player host. Never derived here — this body must not read the
        /// clock, and neither may the buttons.
        var itemNeighbours = PlayerItemNavigation.Neighbours.none
        /// Plays the neighbour on that side. Routed back through the host's
        /// swapper so two presses can't stack a second decoder teardown on the
        /// first.
        var onStepItem: ((PlayerMediaSwapper.Step) -> Void)?

        // Observe list/selection, not SubtitleModel.parts (the live caption clock).
        @State private var subtitleTracks: [any SubtitleInfo] = []
        @State private var selectedSubtitle: (any SubtitleInfo)?

        var body: some View {
            PlayerControlsOverlay(
                presentation: .init(
                    engine: .ksPlayer, isPlaying: isPlaying,
                    videoInfo: videoInfo,
                    audioTracks: audioTrackOptions, textTracks: textTrackOptions,
                    rate: coordinator.playbackRate,
                    isPipSupported: true,
                    isPipActive: isPipActive, isAspectFill: coordinator.isScaleAspectFill
                ),
                actions: .init(
                    close: onClose, togglePlay: onTogglePlay,
                    togglePip: onTogglePip,
                    resetHideTimer: onResetHideTimer,
                    skip: onSkip,
                    selectAudioTrack: selectAudioTrack, selectTextTrack: selectTextTrack,
                    setRate: { coordinator.playbackRate = $0 },
                    sliderEditingChanged: onSliderEditingChanged,
                    toggleAspectFill: { coordinator.isScaleAspectFill.toggle() },
                    searchSubtitles: onSearchSubtitles,
                    stepItem: onStepItem
                ),
                media: media, isSeeking: $isSeeking, seekPosition: $seekPosition,
                clock: clock, route: AirPlayRouteButton(),
                itemNeighbours: itemNeighbours
            )
            .onReceive(coordinator.subtitleModel.$subtitleInfos) { subtitleTracks = $0 }
            .onReceive(coordinator.subtitleModel.$selectedSubtitleInfo) { selectedSubtitle = $0 }
        }

        private var audioTrackOptions: [PlayerTrackOption] {
            (coordinator.playerLayer?.player.tracks(mediaType: .audio) ?? []).map {
                PlayerTrackOption(id: String($0.trackID), label: $0.name, isSelected: $0.isEnabled)
            }
        }

        private var textTrackOptions: [PlayerTrackOption] {
            subtitleTracks.map {
                PlayerTrackOption(id: $0.subtitleID, label: $0.name, isSelected: selectedSubtitle?.subtitleID == $0.subtitleID)
            }
        }

        private func selectAudioTrack(_ id: String) {
            guard let track = coordinator.playerLayer?.player.tracks(mediaType: .audio).first(where: { String($0.trackID) == id }) else { return }
            coordinator.selectAudioTrack(track)
            coordinator.objectWillChange.send()
        }

        private func selectTextTrack(_ id: String?) {
            coordinator.subtitleModel.selectedSubtitleInfo = subtitleTracks.first { $0.subtitleID == id }
        }

        private func onSliderEditingChanged(editing: Bool) {
            isSeeking = editing
            if editing {
                onSuspendHide()
                coordinator.playerLayer?.pause()
            } else {
                // Clock first: a catch-up seek re-places it on the segment.
                clock.current = seekPosition
                onSeek(seekPosition)
                if isPlaying {
                    coordinator.playerLayer?.play()
                }
                onScheduleHide()
            }
        }
    }
#endif

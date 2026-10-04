import SwiftUI

// Engine observation and scrubbing adapter for the shared standard overlay.
#if !os(tvOS)
    struct LumeEngineControlsOverlay: View {
        @ObservedObject var coordinator: LumeEngineCoordinator
        let media: PlayableMedia
        @Binding var isSeeking: Bool
        @Binding var seekPosition: TimeInterval
        /// The 10 Hz playback clock. Deliberately the `@Observable` object, not
        /// `$clock.current` bindings: reading a tick-driven value in this body
        /// would re-render the whole overlay — and an open `Menu` whose host
        /// keeps re-rendering flickers its items and cancels in-flight taps.
        /// Only the `PlaybackTimeline` leaf reads the clock; this body must never.
        let clock: PlaybackClock
        var onSuspendHide: () -> Void
        var onClose: () -> Void
        var onTogglePlay: () -> Void
        var onResetHideTimer: () -> Void
        var onScheduleHide: () -> Void
        /// Raises the OpenSubtitles browser. `nil` when the search isn't
        /// available for this stream, which also drops the menu entry.
        var onSearchSubtitles: (() -> Void)?
        /// Previous/next stream for the transport pair, resolved once per stream
        /// by the player host. Never derived here — this body must not read the
        /// clock, and neither may the buttons.
        var itemNeighbours = PlayerItemNavigation.Neighbours.none
        /// Plays the neighbour on that side. Routed back through the host's
        /// swapper so two presses can't stack a second decoder teardown on the
        /// first.
        var onStepItem: ((PlayerMediaSwapper.Step) -> Void)?

        var body: some View {
            PlayerControlsOverlay(
                presentation: .init(
                    engine: .lumeEngine, isPlaying: coordinator.isPlaying,
                    videoInfo: coordinator.videoInfo,
                    audioTracks: audioTrackOptions, textTracks: textTrackOptions,
                    rate: coordinator.playbackRate,
                    isPipSupported: coordinator.isPipSupported,
                    isPipActive: coordinator.isPipActive
                ),
                actions: .init(
                    close: onClose, togglePlay: onTogglePlay,
                    togglePip: coordinator.togglePictureInPicture,
                    resetHideTimer: onResetHideTimer,
                    skip: coordinator.skip,
                    selectAudioTrack: selectAudioTrack, selectTextTrack: selectTextTrack,
                    setRate: { coordinator.playbackRate = $0 },
                    sliderEditingChanged: onSliderEditingChanged,
                    searchSubtitles: onSearchSubtitles,
                    stepItem: onStepItem
                ),
                media: media, isSeeking: $isSeeking, seekPosition: $seekPosition,
                clock: clock, route: AirPlayRouteButton(),
                itemNeighbours: itemNeighbours
            )
        }

        private var audioTrackOptions: [PlayerTrackOption] {
            coordinator.audioTrackOptions
        }

        private var textTrackOptions: [PlayerTrackOption] {
            coordinator.textTrackOptions
        }

        private func selectAudioTrack(_ id: String) {
            coordinator.selectAudioTrack(id: id)
        }

        private func selectTextTrack(_ id: String?) {
            coordinator.selectTextTrack(id: id)
        }

        private func onSliderEditingChanged(editing: Bool) {
            isSeeking = editing
            if editing {
                onSuspendHide()
            } else {
                // Clock first: a catch-up seek re-places it on the segment.
                clock.current = seekPosition
                coordinator.seek(to: seekPosition)
                onScheduleHide()
            }
        }
    }
#endif

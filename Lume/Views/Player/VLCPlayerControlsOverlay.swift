import SwiftUI
import VLCKit

// Engine observation and scrubbing adapter for the shared standard overlay.
#if !os(tvOS)
    struct VLCPlayerControlsOverlay: View {
        @ObservedObject var coordinator: VLCPlayerCoordinator
        let media: PlayableMedia
        @Binding var isSeeking: Bool
        @Binding var seekPosition: TimeInterval
        /// The 10 Hz playback clock, as the `@Observable` object: only the
        /// `PlaybackTimeline` leaf reads it, so ticks never re-render this body
        /// (and with it an open track `Menu`).
        let clock: PlaybackClock
        var onSuspendHide: () -> Void
        var onClose: () -> Void
        var onTogglePlay: () -> Void
        var onResetHideTimer: () -> Void
        var onScheduleHide: () -> Void
        /// Raises the OpenSubtitles browser. `nil` when the search isn't available
        /// for this stream, which also drops the menu entry.
        var onSearchSubtitles: (() -> Void)?
        /// Previous/next stream for the transport pair, resolved once per stream
        /// by the player host. Never derived here — enablement must not depend
        /// on anything the playback clock drives.
        var itemNeighbours = PlayerItemNavigation.Neighbours.none
        /// Plays the neighbour on that side. Routed back through the host's
        /// swapper so two presses can't stack a second decoder teardown on the
        /// first.
        var onStepItem: ((PlayerMediaSwapper.Step) -> Void)?

        var body: some View {
            PlayerControlsOverlay(
                presentation: .init(
                    engine: .vlcKit, isPlaying: coordinator.isPlaying,
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
            coordinator.audioTracks.enumerated().map {
                PlayerTrackOption(id: String($0.offset), label: $0.element.trackName, isSelected: $0.element.isSelectedExclusively)
            }
        }

        private var textTrackOptions: [PlayerTrackOption] {
            coordinator.textTracks.enumerated().map {
                PlayerTrackOption(id: String($0.offset), label: $0.element.trackName, isSelected: $0.element.isSelectedExclusively)
            }
        }

        private func selectAudioTrack(_ id: String) {
            guard let index = Int(id), coordinator.audioTracks.indices.contains(index) else { return }
            coordinator.selectAudioTrack(coordinator.audioTracks[index])
        }

        private func selectTextTrack(_ id: String?) {
            guard let id else { coordinator.selectTextTrack(nil); return }
            guard let index = Int(id), coordinator.textTracks.indices.contains(index) else { return }
            coordinator.selectTextTrack(coordinator.textTracks[index])
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

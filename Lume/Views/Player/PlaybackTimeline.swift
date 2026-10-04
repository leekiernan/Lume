//
//  PlaybackTimeline.swift
//  Lume
//
//  The iOS / macOS controls' scrubber and time labels, shared by every
//  engine's overlay. The only part of an overlay that follows the 10 Hz
//  `PlaybackClock`: an overlay that read the clock in its own body re-rendered
//  on every tick, and an open audio/subtitle `Menu` whose host keeps
//  re-rendering flickers its items and drops taps.
//

import SwiftUI

#if !os(tvOS)
    /// The scrubber and time labels — the only part of the overlay that follows
    /// the 10 Hz playback clock. Isolated in its own view so each tick
    /// invalidates just this leaf: the overlay above (menus, buttons) never
    /// re-renders with it, which is what keeps an open track menu stable and
    /// tappable.
    struct PlaybackTimeline: View {
        var clock: PlaybackClock
        @Binding var isSeeking: Bool
        @Binding var seekPosition: TimeInterval
        var onEditingChanged: (Bool) -> Void

        var body: some View {
            Slider(
                value: Binding<TimeInterval>(
                    get: { isSeeking ? seekPosition : (clock.current.isFinite ? clock.current : 0) },
                    set: { seekPosition = $0 }
                ),
                in: 0 ... max(clock.duration.isFinite ? clock.duration : 1, 1),
                onEditingChanged: onEditingChanged
            )
            .tint(.white)

            HStack {
                Text(PlaybackTimeLabel.clock(isSeeking ? seekPosition : clock.current))
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                Spacer()
                Text(PlaybackTimeLabel.clock(max(clock.duration, 0)))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.caption.monospacedDigit())
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        }
    }
#endif

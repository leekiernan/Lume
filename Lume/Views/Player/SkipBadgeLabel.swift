//
//  SkipBadgeLabel.swift
//  Lume
//
//  How far the current skip run has gone — "+9 min, 40 sec" with its
//  direction — and the time it lands on, large and centred over the picture
//  like the loading spinner, so a climbing run of presses reads as it climbs.
//  While the seek loads it stands in for that spinner, with a small one beside
//  the time. See `SkipAcceleration` and `SkipIndicatorHandoff`.
//

import SwiftUI

struct SkipBadgeLabel: View {
    let badge: SkipBadge
    /// The seek is still loading: the indicator stands in for the spinner.
    let buffering: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                Image(systemName: badge.forward ? "forward.fill" : "backward.fill")
                Text(SkipAcceleration.label(for: badge.press.total))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.system(size: 44, weight: .semibold))
            HStack(spacing: 14) {
                if buffering {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                Text(SkipAcceleration.timeLabel(for: badge.press.target))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 44)
        .padding(.vertical, 26)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(radius: 12)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: badge.press)
    }
}

//
//  SkipBadgeLabel.swift
//  Lume
//
//  How far the last skip press went — "+3 min" with its direction — large and
//  centred over the picture, like the loading spinner, so a climbing run of
//  presses reads as it climbs. See `SkipAcceleration`.
//

import SwiftUI

struct SkipBadgeLabel: View {
    let badge: SkipBadge

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: badge.step < 0 ? "backward.fill" : "forward.fill")
            Text(SkipAcceleration.label(for: badge.step))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 44)
        .padding(.vertical, 26)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(radius: 12)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: badge.step)
    }
}

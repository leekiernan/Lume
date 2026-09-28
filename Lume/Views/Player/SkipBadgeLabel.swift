//
//  SkipBadgeLabel.swift
//  Lume
//
//  How far the skip press just went — "+3m" — above the tvOS skip button,
//  so a climbing run of presses reads as it climbs. See `SkipAcceleration`.
//

import SwiftUI

struct SkipBadgeLabel: View {
    let badge: SkipBadge

    var body: some View {
        Text(SkipAcceleration.label(for: badge.step))
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.opacity)
            .id(badge.id)
    }
}

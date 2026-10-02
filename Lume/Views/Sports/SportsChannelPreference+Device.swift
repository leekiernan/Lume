//
//  SportsChannelPreference+Device.swift
//  Lume
//
//  This device's side of the channel preference: the viewer's preferred audio
//  languages (the player's own list, else the system's) and whether the screen
//  is 4K. Only tvOS reports a TV's resolution; elsewhere FHD is preferred,
//  which plays everywhere without paying for UHD bandwidth.
//

import SwiftUI
#if os(tvOS)
    import UIKit
#endif

extension SportsChannelPreference.Context {
    @MainActor
    static var current: Self {
        Self(
            preferredLanguages: PlayerLanguageOptions.load().preferredAudioLanguages,
            displayIs4K: displayIs4K
        )
    }

    @MainActor
    private static var displayIs4K: Bool {
        #if os(tvOS)
            UIScreen.main.nativeBounds.height >= 2160
        #else
            false
        #endif
    }
}

/// "Mark as Main Channel" in a channel's menu: the viewer's correction to which
/// of their channels count as a broadcaster's flagship for "Big this week".
struct MainChannelMenuItem: View {
    let channelName: String
    @State private var overrides = SportsFlagshipOverrides.shared

    var body: some View {
        let isMain = overrides.isFlagship(channelName)
        Button {
            overrides.toggle(channelName)
        } label: {
            Label(isMain ? "Not a Main Channel" : "Mark as Main Channel", systemImage: isMain ? "star.slash" : "star")
        }
    }
}

//
//  PlatformNavigationTitle.swift
//  Lume
//
//  Applies a navigation title on iOS but suppresses the large title text on
//  tvOS, where the custom tab bar already conveys the active section.
//

import SwiftUI

extension View {
    /// Sets the navigation title on platforms that benefit from it, while
    /// omitting the large title text on tvOS.
    func platformNavigationTitle(_ title: LocalizedStringKey, handlesMacBack: Bool = true) -> some View {
        #if os(tvOS)
            self
        #elseif os(macOS)
            navigationTitle(title)
                .macNavigationBackEnabled(handlesMacBack)
        #else
            navigationTitle(title)
        #endif
    }

    @ViewBuilder
    private func macNavigationBackEnabled(_ enabled: Bool) -> some View {
        if enabled { macNavigationBack() } else { self }
    }
}

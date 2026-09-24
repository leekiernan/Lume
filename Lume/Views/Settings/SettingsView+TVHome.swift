//
//  SettingsView+TVHome.swift
//  Lume
//
//  The tvOS Home settings pane. The rows, their order, custom sections and the
//  promoted hero are all managed by `TVSectionLayoutDetail`, shared with every
//  section surface; this is only where Settings hosts it for Home.
//

import SwiftUI

#if os(tvOS)

    extension SettingsView {
        var tvHomeLayoutDetail: some View {
            TVSectionLayoutDetail(surface: .home)
        }
    }

#endif

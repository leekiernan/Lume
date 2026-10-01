//
//  SettingsView+TVTabBarEntry.swift
//  Lume
//
//  Getting from the tab bar into Settings' sidebar on tvOS. Split from
//  SettingsView.swift, which sits at SwiftLint's file-length limit.
//

import SwiftUI

#if os(tvOS)
    extension SettingsView {
        /// Pressing down from the tab bar lands on whatever sits under the
        /// Settings tab — the detail pane's top row, never the sidebar, which
        /// is far off to the left. This invisible full-width strip across the
        /// top is nearer than any of them, so it catches that move and hands it
        /// to the selected sidebar category. It's focusable only while focus is
        /// outside Settings, so moving up from the panes still reaches the tab
        /// bar.
        var tvTabBarEntryCatcher: some View {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .focusable(focusedCategory == nil && !detailFocused)
                .focused($tabBarEntryFocused)
                .onChange(of: tabBarEntryFocused) { _, isFocused in
                    guard isFocused else { return }
                    // Same-frame focus writes from a focus callback get dropped.
                    Task { @MainActor in focusedCategory = selectedCategory }
                }
                // Just below the tab bar, which overlaps this overlay's top by
                // ~60 pt, and above the panes' first rows (72 pt top padding).
                // Measured upstream on tvOS 26.5: y ≈ 130 between a tab bar
                // ending at 114 and the first detail row at 157.
                .padding(.top, 77)
        }
    }
#endif

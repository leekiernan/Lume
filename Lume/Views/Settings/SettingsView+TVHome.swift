//
//  SettingsView+TVHome.swift
//  Lume
//
//  The tvOS Library pane: picks an area (Home, Movies, Series, Live TV) or the
//  Sports settings sibling. Areas can be switched off entirely and show whatever
//  configuration they own —
//  its rows via `TVSectionLayoutDetail`, its categories via Content Management.
//  Mirrors the iOS/macOS `LibrarySettingsView`, which uses a list and drill-ins
//  instead; the tvOS sidebar is already long, so the areas share one category
//  here.
//

import SwiftUI

#if os(tvOS)

    extension SettingsView {
        func tvLibraryDetail(proxy: ScrollViewProxy) -> some View {
            VStack(alignment: .leading, spacing: 28) {
                tvAreaPicker
                if showingSportsSettings {
                    TVSportsSettingsPane()
                } else {
                    tvAreaEnableRow
                    tvAreaEnableNote

                    if AppAreaSettings.isEnabled(layoutArea, disabledRaw: disabledAreasRaw) {
                        if let surface = layoutArea.sectionSurface {
                            TVSectionLayoutDetail(surface: surface)
                                // Rebuild on switch: the pane's @AppStorage keys are
                                // fixed at init, so it has to be a new view per area.
                                .id(surface)
                        }

                        if let type = layoutArea.categoryType {
                            tvAreaCategoriesRow(type: type, proxy: proxy)
                        }
                    } else {
                        Text("This area is switched off. It has no tab, and its content is skipped when playlists sync.")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Mirrors Content Management's type picker: plain text in
        /// `TVSettingsActionButtonStyle`, which carries the focus highlight and
        /// the prominent resting fill for the current one.
        private var tvAreaPicker: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Area")

                HStack(spacing: 12) {
                    ForEach(AppArea.allCases) { area in
                        Button {
                            layoutArea = area
                            showingSportsSettings = false
                            showingAreaCategories = false
                        } label: {
                            Text(area.title)
                        }
                        .buttonStyle(TVSettingsActionButtonStyle(prominent: layoutArea == area))
                        .accessibilityAddTraits(layoutArea == area ? [.isSelected] : [])
                    }

                    Button {
                        showingSportsSettings = true
                        showingAreaCategories = false
                    } label: {
                        Text("Sports")
                    }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: showingSportsSettings))
                    .accessibilityAddTraits(showingSportsSettings ? [.isSelected] : [])
                }
                .focusSection()
            }
        }

        private var tvAreaEnableRow: some View {
            let enabled = AppAreaSettings.isEnabled(layoutArea, disabledRaw: disabledAreasRaw)
            let canDisable = AppAreaSettings.canDisable(layoutArea, disabledRaw: disabledAreasRaw)
            return Button {
                // Mark this before changing AppStorage. Removing or inserting
                // the area detail can otherwise make tvOS briefly focus the
                // sidebar, whose focus-follow behaviour would navigate away.
                restoringLibraryAreaToggleFocus = true
                AppAreaSettings.setEnabled(!enabled, for: layoutArea)
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    Text("Show \(layoutArea.displayName)")
                    Spacer(minLength: 0)
                    Text(enabled ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
            .focused($libraryAreaToggleFocused)
            .onChange(of: disabledAreasRaw) { _, _ in
                guard restoringLibraryAreaToggleFocus else { return }

                // This callback belongs to the updated view hierarchy. Yield
                // once more so inserted/removed rows finish their layout before
                // asking the focus engine to return to this stable row.
                Task { @MainActor in
                    await Task.yield()
                    libraryAreaToggleFocused = true
                    await Task.yield()
                    restoringLibraryAreaToggleFocus = false
                }
            }
            // The last area standing can't be switched off — there would be no
            // navigation left.
            .disabled(enabled && !canDisable)
            .accessibilityValue(enabled ? Text("On") : Text("Off"))
        }

        /// Home has no content of its own — it draws on the other areas — so
        /// switching it off is purely a navigation change.
        @ViewBuilder
        private var tvAreaEnableNote: some View {
            if layoutArea == .home {
                Text("Home draws on the other areas, so switching it off removes its tab without changing what syncs.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            }
        }

        /// The categories fold open under the button rather than replacing the
        /// pane. Swapping the whole detail destroyed the focused button, so tvOS
        /// handed focus back to the sidebar — which reverts any drill-in, closing
        /// the categories again the instant they opened.
        private func tvAreaCategoriesRow(type: CategoryType, proxy: ScrollViewProxy) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Categories")

                Button {
                    showingAreaCategories.toggle()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 22, weight: .medium))
                        Text(showingAreaCategories ? "Hide Categories" : "Manage Categories")
                        Spacer(minLength: 0)
                        Image(systemName: showingAreaCategories ? "chevron.down" : "chevron.right")
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())

                if showingAreaCategories {
                    // Still gated: this is the surface the standalone Content
                    // Management screen protected before the two were merged.
                    ParentalGateView {
                        ContentManagementView(fixedType: type, embeddedProxy: proxy)
                    }
                    .focusSection()
                } else {
                    Text("Hide and reorder the categories your provider supplies, and choose what appears in the browse sidebar.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }
            }
        }
    }

#endif

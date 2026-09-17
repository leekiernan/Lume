//
//  LibrarySettingsView.swift
//  Lume
//
//  One screen for everything that shapes what the app shows, organised by the
//  same areas as the top navigation: Home, Movies, Series, Live TV. It replaces
//  the separate "Content Management" and "Layout" entries, which split the same
//  decisions across two places — one by content type, the other by page.
//
//  Each area can be switched off entirely, which removes its tab *and* stops it
//  syncing (see `AppAreaSettings`). Drilling into an area gives whatever it has
//  to configure: rows for Home, rows and categories for Movies and Series,
//  categories and channels for Live TV.
//

#if !os(tvOS)

    import SwiftUI

    struct LibrarySettingsView: View {
        @AppStorage(AppAreaSettings.disabledAreasKey) private var disabledAreasRaw = ""

        var body: some View {
            List {
                Section {
                    ForEach(AppArea.allCases) { area in
                        row(for: area)
                    }
                } header: {
                    Text("Areas")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Switch an area off to remove it from the navigation and stop syncing it. Anything already downloaded is kept, so turning it back on restores it straight away.")
                        // Home has no content type of its own, so its switch is
                        // purely a navigation change.
                        Text("Home draws on the other areas, so switching it off removes its tab without changing what syncs.")
                    }
                }
            }
            .platformNavigationTitle("Library")
        }

        /// An area's row: the drill-in on the left, its on/off switch on the
        /// right. The switch is a separate control rather than a swipe action so
        /// it reads the same as the per-row switches inside.
        private func row(for area: AppArea) -> some View {
            let enabled = AppAreaSettings.isEnabled(area, disabledRaw: disabledAreasRaw)
            return HStack {
                NavigationLink {
                    LibraryAreaSettingsView(area: area)
                } label: {
                    Label(area.title, systemImage: area.systemImage)
                        .foregroundStyle(enabled ? .primary : .secondary)
                }

                // Labelled (not `Toggle("")`) so VoiceOver reads the area's name
                // and no empty key lands in the string catalog.
                Toggle(area.title, isOn: enabledBinding(for: area))
                    .labelsHidden()
                    // The last area standing can't be switched off — there would
                    // be no navigation left.
                    .disabled(!AppAreaSettings.canDisable(area, disabledRaw: disabledAreasRaw))
            }
        }

        private func enabledBinding(for area: AppArea) -> Binding<Bool> {
            Binding(
                get: { AppAreaSettings.isEnabled(area, disabledRaw: disabledAreasRaw) },
                set: { isOn in
                    disabledAreasRaw = AppAreaSettings.settingEnabled(
                        isOn, for: area, disabledRaw: disabledAreasRaw
                    )
                }
            )
        }
    }

    /// One area's configuration: its rows inline (a short list), and its
    /// categories behind a drill-in, since category management is a screen in
    /// its own right with search, bulk actions and reordering.
    struct LibraryAreaSettingsView: View {
        let area: AppArea

        var body: some View {
            // Each child titles itself with the area's own name, so no title is
            // set here — two on one destination is ambiguous in SwiftUI.
            if let surface = area.sectionSurface {
                SectionLayoutSettingsView(surface: surface, categoryType: area.categoryType)
            } else if let type = area.categoryType {
                // Live TV has no configurable rows — its categories *are* the
                // screen, so skip the intermediate level entirely.
                ContentManagementView(fixedType: type)
            }
        }
    }

#endif

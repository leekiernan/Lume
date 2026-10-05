//
//  LibrarySettingsView.swift
//  Lume
//
//  One screen for everything that shapes what the app shows, organised by the
//  same areas as the top navigation: Home, Movies, Series, Live TV, and Sports.
//  the separate "Content Management" and "Layout" entries, which split the same
//  decisions across two places — one by content type, the other by page.
//
//  Each area can be switched off entirely, which removes its tab *and* stops it
//  syncing (see `AppAreaSettings`). Drilling into an area gives whatever it has
//  to configure: rows for Home, rows and categories for Movies and Series,
//  categories and channels for Live TV. Sports is a sibling settings item but
//  remains operationally dependent on Live TV because fixtures open its EPG
//  channels.
//

#if !os(tvOS)

    import SwiftUI

    struct LibrarySettingsView: View {
        @AppStorage(AppAreaSettings.disabledAreasKey) private var disabledAreasRaw = ""
        @AppStorage(SportsSyncService.enabledKey) private var sportsEnabled = SportsSyncService.enabledDefault

        var body: some View {
            List {
                Section {
                    ForEach(AppArea.allCases) { area in
                        row(for: area)
                    }

                    areaRow(title: "Sports", systemImage: "sportscourt", enabled: $sportsEnabled) {
                        SportsSettingsView()
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
            areaRow(title: area.title, systemImage: area.systemImage,
                    enabled: enabledBinding(for: area), canDisable: AppAreaSettings.canDisable(area, disabledRaw: disabledAreasRaw))
            {
                LibraryAreaSettingsView(area: area)
            }
        }

        private func areaRow(title: LocalizedStringKey, systemImage: String, enabled: Binding<Bool>,
                             canDisable: Bool = true, @ViewBuilder destination: () -> some View) -> some View
        {
            HStack(spacing: 16) {
                NavigationLink(destination: destination) {
                    Label(title, systemImage: systemImage)
                        .foregroundStyle(enabled.wrappedValue ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(title, isOn: enabled)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!canDisable)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func enabledBinding(for area: AppArea) -> Binding<Bool> {
            Binding(
                get: { AppAreaSettings.isEnabled(area, disabledRaw: disabledAreasRaw) },
                set: { isOn in
                    // `setEnabled` is the sole persistent writer. Assigning to
                    // AppStorage afterwards can race another paired write and
                    // overwrite its area set without advancing its generation.
                    AppAreaSettings.setEnabled(isOn, for: area)
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
                // Provider categories are a separate drill-in, just as they
                // are for Movies/Series, not a substitute for home sections.
                List {
                    LibraryCategorySettingsSection(categoryType: type)
                }
                .platformNavigationTitle(area.title)
            }
        }
    }

    /// Provider-category management stays distinct from an area's home rows.
    /// Shared by the section-based areas and Live TV's category-only settings.
    struct LibraryCategorySettingsSection: View {
        let categoryType: CategoryType

        var body: some View {
            Section {
                NavigationLink {
                    ContentManagementView(fixedType: categoryType)
                } label: {
                    Label("Categories", systemImage: "square.grid.2x2")
                }
            } footer: {
                Text("Hide and reorder the categories your provider supplies, and choose what appears in the browse sidebar.")
            }
        }
    }

#endif

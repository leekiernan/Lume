//
//  SportsSectionsSettingsView.swift
//  Lume
//
//  Settings ▸ Library ▸ Sports ▸ Sections: the Sports hub's rows — one per
//  follow — hidden with the eye and reordered by dragging, the same row and
//  gestures as Content Management. The order is the follow list's own, so it
//  also leads the Home shelf; hiding only takes a follow off the hub
//  (`SportsHubLayout`). The tvOS equivalent sits inline in `TVSportsSettingsPane`.
//

import SwiftUI

#if !os(tvOS)

    struct SportsSectionsSettingsView: View {
        @State private var follows = SportsFollowService.shared
        @AppStorage(SportsHubLayout.hiddenKey) private var hiddenRaw = ""

        private var entries: [SportsBrowseSidebar.Entry] {
            SportsHubGrouping(scope: .all, follows: follows.follows, store: .shared).sidebarEntries
        }

        var body: some View {
            List {
                Section {
                    if entries.isEmpty {
                        Text("Follow teams and leagues to build your Sports hub.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries, id: \.key) { entry in
                        ContentManageRow(
                            title: entry.title,
                            isHidden: SportsHubLayout.hidden(hiddenRaw).contains(entry.key),
                            onToggleHidden: { hiddenRaw = SportsHubLayout.toggling(entry.key, in: hiddenRaw) },
                            icon: { crest(entry.logoURL) }
                        )
                    }
                    .onMove { source, destination in
                        follows.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text("Sections")
                } footer: {
                    Text("Hide a team or league to take its row off the Sports hub — it stays followed. Drag to reorder: the hub's rows follow this order, and the first few lead the Home shelf.")
                }
            }
            .platformNavigationTitle("Sections")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            #endif
        }

        private func crest(_ url: URL?) -> some View {
            CachedAsyncImage(url: url, maxPixelSize: 48) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
        }
    }

#endif

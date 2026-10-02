//
//  SettingsView+Sports.swift
//  Lume
//
//  Sports is a sibling in Settings > Library, while remaining operationally
//  dependent on the profile's Live TV area because fixtures resolve to EPG
//  channels. This pane manages the profile-scoped Sports switch, follows, tab
//  and a manual refresh.
//

import SwiftUI

#if !os(tvOS)

    struct SportsSettingsView: View {
        @AppStorage(SportsSyncService.enabledKey) private var enabled = SportsSyncService.enabledDefault
        @AppStorage(SportsSyncService.tabEnabledKey) private var tabEnabled = SportsSyncService.tabEnabledDefault
        @AppStorage(SportsSyncService.hideScoresKey) private var hideScores = false
        @State private var sync = SportsSyncService.shared
        @State private var showingManageTeams = false

        var body: some View {
            Form {
                Section {
                    Toggle("Show Sports", isOn: $enabled)
                } footer: {
                    Text("Sports uses your Live TV channels to open games. Turning it off stops Sports refreshes for this profile.")
                }
                if enabled {
                    teamsSection
                    tabSection
                    scoresSection
                    SportsAlertSettingsSection()
                    refreshSection
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Sports")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .sheet(isPresented: $showingManageTeams) {
                    ManageTeamsSheet()
                }
                .onChange(of: enabled) { _, _ in
                    SportsSyncService.shared.availabilityDidChange()
                    SportsFollowService.shared.reload()
                }
        }

        private var teamsSection: some View {
            Section {
                NavigationLink {
                    SportsSectionsSettingsView()
                } label: {
                    Label("Sections", systemImage: "list.bullet")
                }
                Button {
                    showingManageTeams = true
                } label: {
                    Label("Manage Teams", systemImage: "person.2.badge.plus")
                }
            } header: {
                Text("Following")
            } footer: {
                Text("Sections orders the Sports hub and hides rows from it; Manage Teams follows and unfollows.")
            }
        }

        private var tabSection: some View {
            Section {
                Toggle("Show Sports Tab", isOn: $tabEnabled)
            } footer: {
                Text("Show the Sports tab. The fixtures rail on Home follows your Home layout settings.")
            }
        }

        private var scoresSection: some View {
            Section {
                Toggle("Hide Scores", isOn: $hideScores)
            } footer: {
                Text("Fixture cards and game details leave out scores and results, along with the match timeline and stats.")
            }
        }

        private var refreshSection: some View {
            Section {
                Button {
                    sync.syncNow()
                } label: {
                    HStack {
                        Label("Refresh Now", systemImage: "arrow.triangle.2.circlepath")
                        if sync.isSyncing {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(sync.isSyncing)
            } header: {
                Text("Sports Data")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixtures, live scores and standings refresh whenever you open Home or the Sports tab, and every minute while they're on screen.")
                    Text(lastRefreshText)
                    Text("Scores and schedules provided by ESPN")
                }
            }
        }

        private var lastRefreshText: String {
            guard let last = sync.lastRefresh else {
                return String(localized: "Sports haven't refreshed yet.")
            }
            let relative = last.formatted(.relative(presentation: .named))
            return String(localized: "Last refreshed \(relative)")
        }
    }

#endif

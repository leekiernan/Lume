//
//  SettingsView+Sports.swift
//  Lume
//
//  Sports belongs to Live TV because fixtures resolve to EPG channels. The
//  dedicated pane is reached from Settings > Library > Live TV and manages the
//  profile-scoped Sports switch, follows, tab and refresh schedule.
//

import SwiftUI

#if !os(tvOS)

    struct SportsSettingsView: View {
        @AppStorage(SportsSyncService.enabledKey) private var enabled = SportsSyncService.enabledDefault
        @AppStorage(SportsSyncService.tabEnabledKey) private var tabEnabled = SportsSyncService.tabEnabledDefault
        @AppStorage(SportsSyncService.syncFrequencyKey)
        private var freqRaw = SportsSyncService.defaultFrequency.rawValue
        @State private var sync = SportsSyncService.shared
        @State private var showingManageTeams = false

        private var frequency: Binding<SyncFrequency> {
            Binding(
                get: { SyncFrequency(rawValue: freqRaw) ?? SportsSyncService.defaultFrequency },
                set: { freqRaw = $0.rawValue }
            )
        }

        var body: some View {
            Form {
                Section {
                    Toggle("Enable Sports", isOn: $enabled)
                } footer: {
                    Text("Sports uses your Live TV channels to open games. Turning it off stops Sports refreshes for this profile.")
                }
                if enabled {
                    teamsSection
                    tabSection
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
                Button {
                    showingManageTeams = true
                } label: {
                    Label("Manage Teams", systemImage: "person.2.badge.plus")
                }
            } header: {
                Text("Following")
            }
        }

        private var tabSection: some View {
            Section {
                Toggle("Show Sports Tab", isOn: $tabEnabled)
            } footer: {
                Text("Show the Sports tab. The fixtures rail on Home follows your Home layout settings.")
            }
        }

        private var refreshSection: some View {
            Section {
                Picker("Refresh", selection: frequency) {
                    ForEach(SyncFrequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                .pickerStyle(.menu)

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
                Text("Automatic Refresh")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixtures, live scores and standings refresh automatically in the background at this interval.")
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

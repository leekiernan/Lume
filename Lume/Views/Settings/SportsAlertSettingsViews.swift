//
//  SportsAlertSettingsViews.swift
//  Lume
//
//  Settings › Sports › Alerts while watching: when alerts may show over the
//  player, and — sport by sport, as a scores app's notification settings
//  are laid out — which events raise one. Only the sports of the teams this
//  profile follows are listed; alerts are for followed teams.
//

import SwiftUI

extension SportsAlertSettings.Mode {
    var title: LocalizedStringKey {
        switch self {
        case .off: "Off"
        case .liveTV: "During Live TV"
        case .everything: "During Everything"
        }
    }
}

extension SportsAlert.Kind {
    var settingsTitle: LocalizedStringKey {
        switch self {
        case .score: "Goals and Scores"
        case .kickoff: "Kick-off"
        case .halfTime: "Half-time"
        case .finalResult: "Final Result"
        }
    }
}

enum SportsAlertSettingsModel {
    /// The sports of the followed teams, in the order alerts can be set for.
    @MainActor
    static var followedSports: [String] {
        let sports = Set(SportsFollowService.shared.follows
            .filter { $0.kind == .team }
            .compactMap { SportsSyncService.leagueId(fromTeamID: $0.key) }
            .compactMap { leagueId in SportsCatalog.league(id: leagueId)?.sport })
        return SportsAlertSettings.sports.filter(sports.contains)
    }

    static func name(of sport: String) -> LocalizedStringKey {
        names[sport] ?? LocalizedStringKey(sport)
    }

    private static let names: [String: LocalizedStringKey] = [
        "soccer": "Football",
        "football": "American Football",
        "basketball": "Basketball",
        "hockey": "Ice Hockey",
        "baseball": "Baseball",
        "rugby": "Rugby Union",
        "rugby-league": "Rugby League",
        "australian-football": "Australian Football",
        "cricket": "Cricket",
        "tennis": "Tennis",
        "lacrosse": "Lacrosse"
    ]
}

#if os(tvOS)

    /// The tvOS settings pane's alert section.
    struct TVSportsAlertSettingsSection: View {
        @AppStorage(ProfileScopedPreferences.key(SportsAlertSettings.baseKey)) private var raw = ""

        private var settings: SportsAlertSettings {
            SportsAlertSettings(raw: raw)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Alerts While Watching")
                    TVOptionCycleRow(
                        title: "Show Alerts",
                        valueLabel: String(localized: settings.mode.titleResource)
                    ) {
                        update { value in
                            let modes = Array(SportsAlertSettings.Mode.allCases)
                            let index = modes.firstIndex(of: value.mode) ?? 0
                            value.mode = modes[(index + 1) % modes.count]
                        }
                    }
                    Text("For the teams you follow. Never for the game you're watching — the stream can be behind.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
                if settings.mode != .off {
                    ForEach(SportsAlertSettingsModel.followedSports, id: \.self) { sport in
                        VStack(alignment: .leading, spacing: 8) {
                            TVSettingsSectionLabel(SportsAlertSettingsModel.name(of: sport))
                            ForEach(SportsAlert.Kind.allCases, id: \.self) { kind in
                                TVOptionToggleRow(title: kind.settingsTitle, isOn: binding(kind, sport: sport))
                            }
                        }
                    }
                }
            }
        }

        private func binding(_ kind: SportsAlert.Kind, sport: String) -> Binding<Bool> {
            Binding(
                get: { settings.alerts(kind, sport: sport) },
                set: { isOn in update { $0.set(kind, isOn, sport: sport) } }
            )
        }

        private func update(_ change: (inout SportsAlertSettings) -> Void) {
            var value = settings
            change(&value)
            raw = value.raw
        }
    }

#else

    /// The iOS / macOS form section.
    struct SportsAlertSettingsSection: View {
        @AppStorage(ProfileScopedPreferences.key(SportsAlertSettings.baseKey)) private var raw = ""

        private var settings: SportsAlertSettings {
            SportsAlertSettings(raw: raw)
        }

        var body: some View {
            Section {
                Picker("Show Alerts", selection: Binding(
                    get: { settings.mode },
                    set: { mode in update { $0.mode = mode } }
                )) {
                    ForEach(SportsAlertSettings.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if settings.mode != .off {
                    ForEach(SportsAlertSettingsModel.followedSports, id: \.self) { sport in
                        NavigationLink(SportsAlertSettingsModel.name(of: sport)) {
                            Form {
                                ForEach(SportsAlert.Kind.allCases, id: \.self) { kind in
                                    Toggle(kind.settingsTitle, isOn: Binding(
                                        get: { settings.alerts(kind, sport: sport) },
                                        set: { isOn in update { $0.set(kind, isOn, sport: sport) } }
                                    ))
                                }
                            }
                            .navigationTitle(SportsAlertSettingsModel.name(of: sport))
                            .macNavigationBack()
                        }
                    }
                }
            } header: {
                Text("Alerts While Watching")
            } footer: {
                Text("For the teams you follow. Never for the game you're watching — the stream can be behind.")
            }
        }

        private func update(_ change: (inout SportsAlertSettings) -> Void) {
            var value = settings
            change(&value)
            raw = value.raw
        }
    }

#endif

extension SportsAlertSettings.Mode {
    var titleResource: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .liveTV: "During Live TV"
        case .everything: "During Everything"
        }
    }
}

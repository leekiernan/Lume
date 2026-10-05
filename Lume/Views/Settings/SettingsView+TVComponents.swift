//
//  SettingsView+TVComponents.swift
//  Lume
//
//  The tvOS sidebar categories, the About detail pane, and the SwiftUI previews,
//  split out of SettingsView to keep that file within the project's size limit.
//

import SwiftData
import SwiftUI

#if os(tvOS)

    // MARK: - tvOS settings categories

    /// The top-level settings categories shown in the tvOS sidebar.
    enum SettingsCategory: String, CaseIterable, Identifiable {
        /// Content/Home/TV Guide/Sports are one "Library" category; TV Guide's
        /// sources live under Playlists instead of their own category.
        case premium, playlists, profiles, library, search, integrations, player, storage, about

        var id: String {
            rawValue
        }

        var title: LocalizedStringKey {
            switch self {
            case .premium: "Premium"
            case .playlists: "Playlists"
            case .profiles: "Profiles"
            case .library: "Library"
            case .search: "Search"
            case .storage: "Storage"
            case .integrations: "Integrations"
            case .player: "Player"
            case .about: "About"
            }
        }
    }

    extension SettingsView {
        /// The drilled-in options pane for a single engine.
        func tvEngineOptionsDetail(for engine: PlayerEngineKind) -> some View {
            VStack(alignment: .leading, spacing: 28) {
                Text("\(engine.displayName) Options")
                    .font(.system(size: TVSettingsMetrics.paneTitleFontSize, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                switch engine {
                case .vlcKit:
                    VLCEngineSettingsTVDetail()
                case .ksPlayer:
                    KSEngineSettingsTVDetail()
                case .lumeEngine:
                    LumeEngineSettingsTVDetail()
                case .avPlayer:
                    Text("AVPlayer has no configurable options.")
                        .tvSettingsFooter()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        var tvAboutDetail: some View {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("About")

                    TVSettingsSummary(systemImage: "play.tv.fill", title: Text("Lume"), detail: Text("Version \(SupportInfo.appVersion)"))
                }

                tvSupportSection

                TVDiagnosticsSection()

                tvCreditsSection
            }
        }

        /// Read-only acknowledgements for the tvOS About pane. Apple TV can't open
        /// a URL, so the licences and source address are shown as plain text;
        /// names / licences / URLs come from `CreditsInfo` to match the iOS list.
        private var tvCreditsSection: some View {
            VStack(alignment: .leading, spacing: 16) {
                TVSettingsSectionLabel("Acknowledgements")

                Text("Lume is free, open-source software, licensed under the GNU Affero General Public License v3.")
                    .font(.system(size: TVSettingsMetrics.explanatoryFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                VStack(spacing: 2) {
                    ForEach(CreditsInfo.libraries) { library in
                        tvCreditRow(name: library.name, license: library.license)
                    }
                }

                // swiftlint:disable:next line_length
                Text("Artwork, ratings and details are provided by TMDB, MDBList, and Trakt, and intro/recap skip data by IntroDB. This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.system(size: TVSettingsMetrics.explanatoryFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                TVSettingsValueRow("Source", value: CreditsInfo.sourceCode)
            }
        }

        /// A read-only name / licence row styled like `TVSettingsValueRow`, but
        /// with verbatim text on both sides (the library name is a proper noun and
        /// the licence label isn't translated).
        private func tvCreditRow(name: String, license: String) -> some View {
            HStack(spacing: 16) {
                Text(verbatim: name)
                Spacer(minLength: 16)
                Text(verbatim: license)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: TVSettingsMetrics.rowFontSize))
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.vertical, TVSettingsMetrics.rowVPadding + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }

    // MARK: - Sports pane

    /// Selected from the Sports sibling in Library. Sports still requires the
    /// Live TV area at runtime because it opens fixtures on those channels.
    struct TVSportsSettingsPane: View {
        @AppStorage(SportsSyncService.enabledKey) private var enabled = SportsSyncService.enabledDefault
        @AppStorage(SportsSyncService.tabEnabledKey) private var tabEnabled = SportsSyncService.tabEnabledDefault
        @AppStorage(SportsSyncService.hideScoresKey) private var hideScores = false
        @State private var sync = SportsSyncService.shared
        @State private var showManageTeams = false
        @State private var follows = SportsFollowService.shared
        @State private var isReordering = false
        @AppStorage(SportsHubLayout.hiddenKey) private var hiddenRaw = ""
        /// The settings column's scroll view, which the sections list scrolls
        /// to keep a lifted row on screen.
        let proxy: ScrollViewProxy

        var body: some View {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Sports")

                    TVOptionToggleRow(title: "Show Sports", isOn: $enabled, showsIndicator: true)

                    if enabled {
                        Button {
                            showManageTeams = true
                        } label: {
                            HStack(spacing: 16) {
                                Label("Manage Teams", systemImage: "person.2.badge.plus")
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 22, weight: .semibold))
                            }
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())

                        TVOptionToggleRow(title: "Show Sports Tab", isOn: $tabEnabled)
                        TVOptionToggleRow(title: "Hide Scores", isOn: $hideScores)
                    }
                }

                if enabled, !follows.follows.isEmpty {
                    sectionsList
                }

                if enabled {
                    TVSportsAlertSettingsSection()
                }

                if enabled {
                    VStack(alignment: .leading, spacing: 8) {
                        TVSettingsSectionLabel("Sports Data")

                        Button {
                            sync.syncNow()
                        } label: {
                            HStack(spacing: 16) {
                                Text(sync.isSyncing ? "Refreshing…" : "Refresh Now")
                                Spacer(minLength: 0)
                                if sync.isSyncing {
                                    ProgressView()
                                }
                            }
                        }
                        .buttonStyle(TVSettingsRowButtonStyle())
                        .disabled(sync.isSyncing)

                        TVSettingsValueRow("Last Refreshed", value: lastRefreshText)
                    }
                }

                Text("Follow leagues and teams to build your Sports Hub. Fixtures, live scores and standings come from ESPN, and each game links to a channel in your playlists.")
                    .tvSettingsFooter()
            }
            .fullScreenCover(isPresented: $showManageTeams) {
                TVManageTeamsPane()
            }
        }

        /// A relative "last refreshed" line, or "Never" before the first refresh.
        private var lastRefreshText: String {
            if let last = sync.lastRefresh {
                return last.formatted(.relative(presentation: .named))
            }
            return String(localized: "Never")
        }

        /// The hub's rows, one per follow: eye to take one off the hub (it stays
        /// followed), select to lift and move — Content Management's list. The
        /// order is the follow list's, so it also leads the Home shelf.
        private var sectionsList: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Sections")
                TVReorderableContentList(
                    items: follows.follows,
                    title: sectionTitle,
                    isHidden: { SportsHubLayout.hidden(hiddenRaw).contains($0.key) },
                    onToggleHidden: { hiddenRaw = SportsHubLayout.toggling($0.key, in: hiddenRaw) },
                    onCommitOrder: { follows.setOrder($0) },
                    isReordering: $isReordering,
                    scrollProxy: proxy
                )
                Text("Hide a team or league to take its row off the Sports hub — it stays followed. Select a row to lift it, then move up or down and select again to place.")
                    .tvSettingsFooter()
                    .padding(.top, 4)
            }
        }

        private func sectionTitle(_ follow: SportsFollow) -> String {
            SportsHubGrouping(scope: .all, follows: [follow], store: .shared).sidebarEntries.first?.title ?? follow.key
        }
    }

#endif

#Preview("Empty") {
    SettingsView()
}

#Preview("With Playlists") {
    SettingsView()
        .modelContainer(for: Playlist.self, inMemory: true) { result in
            if case let .success(container) = result {
                let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
                let backup = Playlist(name: "Backup", serverURL: "http://backup.com:8080", username: "user2", password: "pass2")
                container.mainContext.insert(playlist)
                container.mainContext.insert(backup)
            }
        }
}

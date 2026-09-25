import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// Not `private`: read by the SettingsView+Profiles extension (separate file).
    @Environment(ProfileManager.self) var profileManager: ProfileManager?
    @Environment(CloudSyncCoordinator.self) private var cloudSync: CloudSyncCoordinator?
    /// Not `private`: read by the SettingsView+AutoSync extension (separate file).
    @Query var playlists: [Playlist]
    /// Not `private`: read by the SettingsView+Playlists extension (separate file).
    @State var showingAddPlaylist = false
    /// Not `private`: read by the SettingsView+Integrations extension (separate file).
    @State var trakt = TraktService.shared
    @State var simkl = SimklService.shared
    @State var openSubtitles = OpenSubtitlesService.shared
    /// Premium entitlement + paywall presentation. Not `private`: read by the
    /// SettingsView+Playlists / +TVComponents extensions (separate files).
    @State var premium = PremiumManager.shared
    @State var showPaywall = false
    @State var paywallHighlight: PremiumFeature?
    #if DEBUG && !SIDE_LOAD
        /// Force-recompute counter for the DEBUG developer section (separate file).
        @AppStorage(RecommendationSettings.manualRecalculationKey) var recommendationsRecalcToken = 0
    #endif
    /// Legacy single-engine key, kept in sync with the primary engine so a
    /// downgrade still finds the user's preferred engine, and read as the
    /// migration seed for the priority list. See `PlayerEnginePriority`.
    /// Not `private`: engine / playback preferences are read by the
    /// SettingsView+TVPlayer extension (separate file, tvOS player pane).
    @AppStorage(PlayerSettings.engineKey) var engineRaw: String = PlayerEngineKind.defaultValue.rawValue
    @AppStorage(PlayerSettings.enginePriorityKey) var enginePriorityRaw: String = ""
    @AppStorage(PlayerSettings.externalPlayerKey) var externalPlayerRaw: String = ""
    @AppStorage(PlayerSettings.externalPlayerScopeKey)
    var externalPlayerScopeRaw: String = ExternalPlayerScope.default.rawValue
    @AppStorage(PlayerSettings.liveSurfModeKey)
    var liveSurfModeRaw: String = LiveSurfMode.default.rawValue
    #if os(tvOS)
        @AppStorage(PlayerSettings.tvRemoteSwipesKey)
        var tvRemoteSwipes = PlayerSettings.tvRemoteSwipesDefault
    #endif
    @AppStorage(PlayerSettings.Playback.autoPlayNextKey)
    var autoPlayNext = PlayerSettings.Playback.autoPlayNextDefault
    #if os(tvOS)
        /// tvOS only: off tvOS the transport row carries an always-available
        /// Next Episode button, so `PlayerNextUpOverlay`'s outro-armed one —
        /// and with it this switch — has nothing left to control.
        @AppStorage(PlayerSettings.Playback.showNextEpisodeButtonKey)
        var showNextEpisodeButton = PlayerSettings.Playback.showNextEpisodeButtonDefault
    #endif
    @AppStorage(PlayerSettings.Playback.showSkipIntroButtonKey)
    var showSkipIntroButton = PlayerSettings.Playback.showSkipIntroButtonDefault
    /// Comma-separated preferred languages, empty meaning no preference (see `PreferredLanguageList`). Not `private`: read by the SettingsView+Language extension (separate file).
    @AppStorage(PlayerSettings.Language.preferredAudioLanguagesKey) var preferredAudioLanguagesRaw = PlayerSettings.Language.preferredAudioLanguagesDefault

    // Stream-information caption preferences (SettingsView+StreamInfo, separate file).
    #if !os(tvOS)
        @AppStorage(PlayerSettings.StreamInfo.enabledKey)
        var streamInfoEnabled = PlayerSettings.StreamInfo.enabledDefault
    #endif
    @AppStorage(PlayerSettings.StreamInfo.detailLevelKey)
    var streamInfoDetailLevelRaw = PlayerSettings.StreamInfo.detailLevelDefault.rawValue
    @AppStorage(SearchSettings.searchAllPlaylistsKey)
    private var searchAllPlaylists = SearchSettings.searchAllPlaylistsDefault
    #if !os(tvOS)
        /// The app-wide appearance override (System / Dark / Light), applied at
        /// the scene root in `LumeApp`. Not offered on tvOS — the TV UI is
        /// designed dark and a per-app light mode makes no sense there.
        @AppStorage(AppAppearance.storageKey)
        private var appearanceRaw = AppAppearance.defaultValue.rawValue
    #endif
    /// Not `private`: read by the SettingsView+AutoSync extension (separate file).
    @AppStorage(SyncFrequency.storageKey) var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue
    #if !os(tvOS)
        @AppStorage(DownloadManager.maxConcurrentKey) private var maxConcurrent = 1
        @AppStorage(DownloadManager.autoDeleteKey) private var autoDeleteAfterWatching = false
        /// The playlists a swipe-to-delete staged, awaiting confirmation.
        @State private var playlistsPendingDeletion: [Playlist] = []
    #endif

    #if os(tvOS)
        /// The globally-selected playlist, shared with the content tabs. tvOS has
        /// no toolbar switcher: this pane is the management surface where the
        /// active playlist is chosen, and the Play/Pause quick-switch overlay the
        /// fast path that writes the same key. Not `private`: read by the
        /// SettingsView+Playlists extension (separate file).
        @AppStorage(PlaylistSelectionStore.key) var selectedPlaylistID: String = ""
        /// Routes the switch through the blocking overlay (see PlaylistSwitchModel).
        /// Not `private`: read by the SettingsView+Playlists extension.
        @Environment(PlaylistSwitchModel.self) var playlistSwitch: PlaylistSwitchModel?
        /// The category whose content is shown in the right pane. Follows focus
        /// in the sidebar (Apple TV Settings behaviour) and persists once focus
        /// moves into the detail pane.
        @State private var selectedCategory: SettingsCategory = .premium
        @FocusState private var focusedCategory: SettingsCategory?
        /// The playlist drilled into within the Playlists category. When set, its
        /// settings replace the playlist list *in the detail pane* rather than
        /// pushing a full-screen view — a push hides the header tab bar and
        /// strands remote focus once the content scrolls. Not `private`: read by
        /// the SettingsView+Playlists extension (separate file).
        @State var selectedPlaylist: Playlist?
        /// The engine whose options are drilled into within the Player category,
        /// replacing the player detail in place (same reasoning as `selectedPlaylist`).
        /// Not `private`: read by the SettingsView+TVPlayer extension (separate file).
        @State var selectedEngineOptions: PlayerEngineKind?
        /// Which preferred-language pane is drilled into within the Player
        /// category — the ordered list, or its add picker one level deeper —
        /// replacing the player detail in place (same reasoning as
        /// `selectedEngineOptions`). Not `private`: read by the
        /// SettingsView+TVPlayer extension (separate file).
        @State var preferredLanguagePane: PreferredLanguagePane?

        enum PreferredLanguagePane {
            case list, add
        }

        /// Which area the Library category is configuring, and whether it has
        /// drilled into that area's categories. The rows pane is
        /// `TVSectionLayoutDetail`, which owns that surface's stored order,
        /// hidden set and custom rows. Not `private`: read by the
        /// SettingsView+TVHome extension (separate file).
        @State var layoutArea: AppArea = .home
        @State var showingAreaCategories = false
        /// Reasserted after the area's enabled state changes. The rows below the
        /// toggle are inserted/removed by that mutation; without an explicit
        /// anchor tvOS can hand focus back to the Settings sidebar.
        @FocusState var libraryAreaToggleFocused: Bool
        /// An area toggle rebuilds the Library detail below its enable row. The
        /// focus engine can briefly nominate a sidebar item while that happens;
        /// don't interpret that transient focus as user navigation before the
        /// enable row has reclaimed focus.
        @State var restoringLibraryAreaToggleFocus = false
        /// Sports is a Library sibling, not an `AppArea`: it has no catalog of
        /// its own and remains unavailable while the parent Live TV area is off.
        @State var showingSportsSettings = false
        /// Whether the Playlists pane has drilled into the guide's sources.
        @State var showingEPGSources = false
        @AppStorage(AppAreaSettings.disabledAreasKey) var disabledAreasRaw = ""
    #endif

    /// The user's ordered engine fallback list (migrates the legacy single-engine
    /// key on first read). The first entry is the primary engine. Not `private`:
    /// read by the SettingsView+TVPlayer extension (separate file).
    var enginePriority: [PlayerEngineKind] {
        PlayerEnginePriority.resolve(priorityRaw: enginePriorityRaw, legacyEngineRaw: engineRaw)
    }

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            standardBody
        #endif
    }

    // MARK: - iOS / macOS (grouped list)

    #if !os(tvOS)
        private var standardBody: some View {
            NavigationStack {
                List {
                    premiumStatusSection
                    profilesSection
                    playlistsSection
                    librarySection
                    appearanceSection
                    searchSection
                    autoSyncSection
                    // No standalone TV Guide section here: its sources are a
                    // NavigationLink inside `playlistsSection` in this fork,
                    // not their own top-level section.
                    CloudSyncSection()
                    if hasAnyIntegration {
                        integrationsSection
                    }
                    playbackSection
                    downloadsSection
                    playerSection
                    streamInfoSection
                    externalPlayerSection
                    storageSection
                    supportSection
                    aboutSection
                    #if DEBUG && !SIDE_LOAD
                        developerSection
                    #endif
                    diagnosticsSection
                }
                #if os(macOS)
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #endif
                .platformNavigationTitle("Settings")
                .paywall(isPresented: $showPaywall, highlight: paywallHighlight)
                .sheet(isPresented: $showingAddPlaylist) {
                    LoginView(isModal: true)
                }
                .playlistDeletionConfirmation(isPresented: confirmingPlaylistDeletion) {
                    confirmPlaylistDeletion()
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 600)
            #endif
        }

        private var playlistsSection: some View {
            Section {
                if playlists.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text("No Playlists")
                                .foregroundStyle(.secondary)
                            Button("Add Playlist") {
                                showingAddPlaylist = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "tv")
                                    .foregroundStyle(.secondary)
                                    .font(.body)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(playlist.name)
                                    Text(playlist.displayURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer(minLength: 0)
                                PlaylistSyncAccessory(state: playlist.syncState)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .onDelete(perform: deletePlaylists)

                    Button {
                        if canAddPlaylist {
                            showingAddPlaylist = true
                        } else {
                            presentPaywall(.multiplePlaylists)
                        }
                    } label: {
                        Label("Add Playlist", systemImage: canAddPlaylist ? "plus" : "crown")
                    }

                    // The guide's sources are playlist-shaped — a URL with a
                    // sync status, usually created by a playlist — so they live
                    // here rather than in their own top-level entry.
                    NavigationLink {
                        EPGSettingsView()
                    } label: {
                        Label("TV Guide Sources", systemImage: "list.clipboard")
                    }
                }
            } header: {
                Text("Playlists")
            } footer: {
                if playlists.isEmpty {
                    EmptyView()
                } else if premium.isPremium {
                    Text("\(playlists.count) playlists")
                } else {
                    Text("Free includes one playlist. Upgrade to Lume Pro to add more.")
                }
            }
        }

        private var librarySection: some View {
            Section {
                NavigationLink {
                    ParentalGateView { LibrarySettingsView() }
                } label: {
                    Label("Library", systemImage: "square.stack")
                }
                .disabled(playlists.isEmpty)
            } header: {
                Text("Library")
            } footer: {
                Text("Choose which areas appear, the sections on each, and which of your provider's categories they show.")
            }
        }

        private var appearanceSection: some View {
            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Follow the device appearance, or keep Lume always in Dark or Light Mode.")
            }
        }

        private var searchSection: some View {
            Section {
                Toggle("Search All Playlists", isOn: $searchAllPlaylists)
            } header: {
                Text("Search")
            } footer: {
                Text("When off, search only finds content in the active playlist. Turn this on to search across all your playlists.")
            }
        }

        private var playbackSection: some View {
            Section {
                Toggle("Autoplay Next Episode", isOn: $autoPlayNext)
                    .disabled(!premium.isPremium)
                Toggle("Show Skip Intro Button", isOn: $showSkipIntroButton)
                    .disabled(!premium.isPremium)
                if !premium.isPremium {
                    Button {
                        presentPaywall(.playbackControls)
                    } label: {
                        Label("Unlock with Premium", systemImage: "crown")
                    }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Automatically start the next episode when one finishes.")
            }
        }

        private var downloadsSection: some View {
            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    Label("Manage Downloads", systemImage: "arrow.down.circle")
                }

                Stepper(
                    "Max Simultaneous Downloads: \(maxConcurrent)",
                    value: $maxConcurrent,
                    in: 1 ... 5
                )

                Toggle("Auto-Delete After Watching", isOn: $autoDeleteAfterWatching)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Download movies and episodes for offline playback. Auto-delete removes the file once you've finished watching.")
            }
        }

        private var storageSection: some View {
            Section {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    Label("Storage & Cache", systemImage: "internaldrive")
                }
            } header: {
                Text("Storage")
            }
        }

        /// Swipe-to-delete only stages the rows; the deletion runs once the
        /// shared confirmation is accepted, as it does from the detail pane.
        private func deletePlaylists(offsets: IndexSet) {
            playlistsPendingDeletion = offsets.map { playlists[$0] }
        }

        private var confirmingPlaylistDeletion: Binding<Bool> {
            Binding(
                get: { !playlistsPendingDeletion.isEmpty },
                set: { if !$0 { playlistsPendingDeletion = [] } }
            )
        }

        private func confirmPlaylistDeletion() {
            let pending = playlistsPendingDeletion
            playlistsPendingDeletion = []
            withAnimation {
                for playlist in pending {
                    PlaylistDeletion.deleteFromUI(playlist, cloudSync: cloudSync, in: modelContext)
                }
            }
        }
    #endif
}

// MARK: - tvOS (Apple TV Settings-style two-pane layout)

#if os(tvOS)

    extension SettingsView {
        private var tvBody: some View {
            NavigationStack {
                HStack(spacing: 0) {
                    tvSidebar
                    tvDetailContainer
                }
                .tvSettingsBackground()
                .paywall(isPresented: $showPaywall, highlight: paywallHighlight)
                .defaultFocus($focusedCategory, .premium)
                .onChange(of: focusedCategory) { oldValue, newValue in
                    // Backstop for the `defaultFocus` above: if the engine
                    // lands on the geometrically nearest row anyway, correct it
                    // rather than treat it as a choice, which would switch
                    // category and throw away any drill-in on the way past.
                    // Moving *within* the sidebar (`oldValue != nil`) is a real
                    // choice and stands.
                    // Not while the area toggle is putting focus back: tvOS
                    // brushes the sidebar as rows insert, and a second
                    // assertion racing that one leaves the engine on neither.
                    if oldValue == nil, !restoringLibraryAreaToggleFocus,
                       let newValue, newValue != selectedCategory,
                       availableCategories.contains(selectedCategory)
                    {
                        Task { focusedCategory = selectedCategory }
                        return
                    }
                    // Follow focus so the detail pane mirrors the highlighted
                    // category. Ignore nil (focus moved into the detail pane),
                    // which keeps the current selection visible.
                    if let newValue, !restoringLibraryAreaToggleFocus {
                        selectedCategory = newValue
                        // Returning focus to the sidebar leaves any drilled-in
                        // detail (a playlist, or an engine's options), so the
                        // pane reverts to its top-level list.
                        selectedPlaylist = nil
                        selectedEngineOptions = nil
                        preferredLanguagePane = nil
                        showingAreaCategories = false
                        showingEPGSources = false
                    }
                }
                .fullScreenCover(isPresented: $showingAddPlaylist) {
                    LoginView(isModal: true)
                }
            }
        }

        private var tvSidebar: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.system(size: 38, weight: .bold))
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.bottom, 28)

                VStack(spacing: 2) {
                    ForEach(availableCategories) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            Text(category.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(TVSettingsSidebarButtonStyle(isSelected: selectedCategory == category))
                        .focused($focusedCategory, equals: category)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 320, alignment: .leading)
            .padding(.leading, 60)
            .padding(.trailing, 24)
            .padding(.vertical, 72)
            .focusSection()
            // Where focus goes when it enters the sidebar. Stating it means the
            // engine picks the selected row *instead of* the geometrically
            // nearest one, rather than landing on that one and being corrected
            // afterwards — which is visible as the highlight jumping.
            .defaultFocus($focusedCategory, selectedCategory, priority: .userInitiated)
        }

        /// The sidebar categories. Integrations is hidden unless the build has
        /// credentials for at least one of them.
        private var availableCategories: [SettingsCategory] {
            SettingsCategory.allCases.filter {
                $0 != .integrations || hasAnyIntegration
            }
        }

        private var tvDetailContainer: some View {
            tvDetail
        }

        /// The detail pane scrolls, and owns the `ScrollViewReader` the Library
        /// pane's embedded category list needs to keep a lifted row on screen
        /// while it is being repositioned.
        private var tvDetail: some View {
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 36) {
                        switch selectedCategory {
                        case .premium:
                            tvPremiumDetail
                        case .playlists:
                            if let selectedPlaylist {
                                PlaylistDetailView(playlist: selectedPlaylist) {
                                    self.selectedPlaylist = nil
                                }
                            } else if showingEPGSources {
                                EPGSettingsView()
                            } else {
                                tvPlaylistsDetail
                            }
                        case .profiles: TVProfilesSettingsView()
                        case .library: tvLibraryDetail(proxy: proxy)
                        case .search: tvSearchDetail
                        case .storage: StorageManagementView()
                        case .integrations: tvIntegrationsDetail
                        case .player:
                            if let selectedEngineOptions {
                                tvEngineOptionsDetail(for: selectedEngineOptions)
                            } else if let preferredLanguagePane {
                                tvPreferredLanguageDetail(preferredLanguagePane)
                            } else {
                                tvPlayerDetail
                            }
                        case .about: tvAboutDetail
                        }
                    }
                    .frame(maxWidth: TVSettingsMetrics.detailMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 72)
                }
            }
            .focusSection()
        }

        private var tvSearchDetail: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Search")
                TVOptionToggleRow(title: "Search All Playlists", isOn: $searchAllPlaylists)
                Text("When off, search only finds content in the active playlist. Turn this on to search across all your playlists.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.top, 6)
            }
        }
    }

#endif

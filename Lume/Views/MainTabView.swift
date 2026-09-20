//
//  MainTabView.swift
//  Lume
//
//  Main tab-based navigation for the app
//

import SwiftData
import SwiftUI

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    // Optional so previews (which don't inject it) don't crash.
    @Environment(PlaylistSwitchModel.self) private var playlistSwitch: PlaylistSwitchModel?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Query private var playlists: [Playlist]
    /// Categories marked restricted, and categories hidden in Content
    /// Management. Fetched once here so a single source feeds the restriction
    /// context every content surface reads from the environment.
    @Query(filter: #Predicate<Category> { $0.isRestricted }) private var restrictedCategories: [Category]
    @Query(filter: #Predicate<Category> { $0.isHidden }) private var hiddenCategories: [Category]

    @AppStorage(SyncFrequency.storageKey) private var syncFrequencyRaw: String = SyncFrequency.defaultValue.rawValue
    /// Areas switched off in Settings › Library. A disabled area has no tab —
    /// and `ContentSyncManager` skips its content entirely. See `AppAreaSettings`.
    @AppStorage(AppAreaSettings.disabledAreasKey) private var disabledAreasRaw: String = ""
    /// Changes when the viewer switches profile — see `activeProfileToken`.
    @AppStorage(ActiveProfileStore.key) private var activeProfileToken: String = ""
    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""

    /// Selected tab and the Movies/Series navigation stacks, shared so an
    /// `onOpenURL` deep link can switch tabs and push a detail screen.
    @State private var router = DeepLinkRouter()

    /// The stream a `lume://resume` deep link (a Live Activity tap) asked to
    /// reopen. Presented directly here, independent of any tab's own player
    /// cover.
    @State private var resumeMedia: PlayableMedia?

    /// Whether a `lume://downloads` deep link (a download Live Activity tap)
    /// asked for the downloads list. Presented as a sheet from here rather than
    /// pushed into Settings, so the link doesn't disturb whatever the user had
    /// open.
    @State private var showsDownloads = false
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    /// Playlists waiting to be auto-synced, and the one currently shown in the
    /// blocking progress cover. Auto-sync is presented (not silent) so the user
    /// sees progress and waits for it to finish — most importantly right after
    /// adding a playlist, when the app would otherwise look empty and broken.
    @State private var syncQueue: [PlaylistSyncRequest] = []
    @State private var activeSyncRequest: PlaylistSyncRequest?

    /// Playlists we've already auto-synced (or attempted) this session, so the
    /// launch / switch / foreground triggers don't re-present the cover for one
    /// that's already been handled.
    @State private var autoSyncAttempted: Set<UUID> = []

    /// Memo behind `contentRestriction` — see `ContentRestrictionMemo`.
    @State private var restrictionMemo = ContentRestrictionMemo()

    private var syncFrequency: SyncFrequency {
        SyncFrequency.resolve(syncFrequencyRaw)
    }

    /// Re-evaluate auto-sync when the profile or its enabled areas change, even
    /// though neither operation changes the shared playlist rows themselves.
    private var autoSyncTrigger: AutoSyncTrigger {
        AutoSyncTrigger(
            playlistCount: playlists.count,
            activeProfileToken: activeProfileToken,
            disabledAreasRaw: disabledAreasRaw
        )
    }

    /// UI tests seed a fake playlist; auto-sync would present a blocking cover
    /// that can never succeed against the stub server, so skip it there.
    private var isUITesting: Bool {
        CommandLine.arguments.contains("-ui-testing")
    }

    /// Whether the browse UI is covered, or the user is somewhere a rating
    /// sheet has no business appearing — the sync cover, the downloads sheet, or
    /// a playlist / profile switch. Players, paywalls and Settings are not
    /// listed: every one of them reports itself, and `appStoreReviewPrompt`
    /// already holds the fire while any is on screen. Settings has to, because
    /// on every platform that shows the prompt it is a sheet on the library
    /// toolbar rather than a tab, and so invisible to this root.
    private var hasBlockingPresentation: Bool {
        activeSyncRequest != nil
            || showsDownloads
            || playlistSwitch?.isSwitching == true
            || profileManager?.isSwitching == true
    }

    /// Hides categories (and their content) from every browse, Home and Search
    /// surface: the ones hidden in Content Management always, the restricted
    /// ones while a child profile is active.
    ///
    /// Routed through a memo: this root's body re-evaluates whenever any catalog
    /// write moves one of its `@Query`s, and constructing a `ContentRestriction`
    /// digests every excluded id — 433 of them on a real hidden-category set.
    /// The two id sets are cheap to rebuild and compare; the digest is not.
    private var contentRestriction: ContentRestriction {
        restrictionMemo.restriction(
            isActive: profileManager?.activeProfileIsChild ?? false,
            restricted: Set(restrictedCategories.map(\.id)),
            hidden: Set(hiddenCategories.map(\.id))
        )
    }

    private func isOn(_ area: AppArea) -> Bool {
        AppAreaSettings.isEnabled(area, disabledRaw: disabledAreasRaw)
    }

    /// Move off a tab the user has just switched off, so the selection can
    /// never point at a tab that is no longer in the bar.
    private func repairSelectionIfNeeded() {
        guard let area = AppArea.allCases.first(where: { $0.tab == router.selectedTab }),
              !isOn(area),
              let fallback = AppAreaSettings.enabledAreas(disabledRaw: disabledAreasRaw).first
        else { return }
        router.selectedTab = fallback.tab
    }

    var body: some View {
        @Bindable var router = router
        return tabView(selection: $router.selectedTab)
            // Layout preferences are keyed by the active profile, and
            // @AppStorage binds its key when the view is created — so the tabs
            // are rebuilt on a switch to re-read under the new profile. The
            // router lives outside this id, so navigation paths survive.
            .id(activeProfileToken)
            .onChange(of: disabledAreasRaw) { _, _ in repairSelectionIfNeeded() }
        #if os(tvOS)
            .disabled(blockingOverlayOwnsScreen || router.isQuickSwitchPresented)
            // Attached OUTSIDE `.disabled` so the same button closes the modal it
            // opened, and above the tabs but below every player: the engines are
            // presented as `fullScreenCover`s from inside a tab, so their own
            // `onPlayPauseCommand` sits above this one in the focused chain and is
            // never shadowed. The guard covers the plain overlays instead, which
            // tvOS focus reaches straight through.
            .onPlayPauseCommand {
                guard playPauseTogglesQuickSwitch else { return }
                router.isQuickSwitchPresented.toggle()
            }
        #endif
            .environment(router)
            .environment(\.contentRestriction, contentRestriction)
            // A tab switch is the one browse interaction that has no scroll
            // view of its own to stamp from, and it is the moment a merge is
            // most expensive — the incoming tab is re-running its queries.
            .onChange(of: router.selectedTab) {
                ContentIndexingService.shared.noteUserInteraction()
            }
        #if os(iOS)
            .tabBarMinimizeOnScrollDownIfAvailable()
        #endif
            .onOpenURL { url in
                handleDeepLink(url)
            }
        #if !os(macOS)
            .fullScreenCover(item: $resumeMedia) { media in
                FullScreenPlayerView(media: media)
            }
        #endif
            .task(id: autoSyncTrigger) {
                // On launch, playlist insertion, profile switch, or area toggle,
                // sync anything due and repair catalog phases the active profile
                // enables but the most recent successful sync skipped.
                enqueueDueSyncs(playlists)
            }
            .onChange(of: selectedPlaylistID) {
                // On playlist switch, sync the newly selected one if it's due —
                // unless the switch asked to land in the cached catalog instead.
                guard playlistSwitch?.consumeDeferredDueSync() != true else { return }
                if let playlist = playlists.active(for: selectedPlaylistID) {
                    enqueueDueSyncs([playlist])
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // Returning to the foreground re-checks staleness — for a long-lived
                // app this is the practical equivalent of "on launch".
                if phase == .active {
                    enqueueDueSyncs(playlists)
                }
            }
            .syncCover(item: $activeSyncRequest, onDismiss: promoteNextIfIdle)
            .downloadsSheet(isPresented: $showsDownloads)
            .switchProgressOverlay(playlist: playlistSwitch, profile: profileManager)
            // The one fire point for the rating sheet. Here rather than at the
            // eleven player presentation sites: this view is the browse root,
            // so reaching it *is* the "player gone, nothing over it" condition.
            .appStoreReviewPrompt(isBlocked: hasBlockingPresentation)
        #if os(tvOS)
            .overlay { tvOverlays }
        #endif
    }

    #if os(tvOS)
        /// The plain overlays layered over the tabs. One always-mounted container,
        /// so the fade is a transaction over this layer instead of over every
        /// animatable attribute in every live tab.
        private var tvOverlays: some View {
            ZStack {
                if let launch = router.multiViewLaunch {
                    MultiViewScreen(
                        seed: launch.seed,
                        onClose: { router.multiViewLaunch = nil }
                    )
                    // A launch's own id, so a grid started from a channel is a
                    // new view rather than the previous one re-rendered — which
                    // would keep the earlier session and drop the seed.
                    .id(launch.id)
                    .transition(.opacity)
                }

                if router.isQuickSwitchPresented {
                    // Built only while presented: a permanently mounted list of
                    // focusable rows would regrow the focus/AX responder walk
                    // that `activeOnly(_:selection:)` exists to contain.
                    TVQuickSwitchOverlay(router: router, playlists: playlists)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: router.isQuickSwitchPresented)
        }

        private func tabView(selection: Binding<AppTab>) -> some View {
            TabView(selection: selection) {
                Tab(value: AppTab.search) {
                    activeOnly(.search, selection: selection.wrappedValue) { SearchView() }
                } label: {
                    Image(systemName: "magnifyingglass")
                }

                if isOn(.home) {
                    Tab(value: AppTab.home) {
                        activeOnly(.home, selection: selection.wrappedValue) { HomeView() }
                    } label: {
                        Text("Home")
                    }
                }

                if isOn(.movies) {
                    Tab(value: AppTab.movies) {
                        activeOnly(.movies, selection: selection.wrappedValue) { MoviesView() }
                    } label: {
                        Text("Movies")
                    }
                }

                if isOn(.series) {
                    Tab(value: AppTab.series) {
                        activeOnly(.series, selection: selection.wrappedValue) { SeriesView() }
                    } label: {
                        Text("Series")
                    }
                }

                if isOn(.liveTV) {
                    Tab(value: AppTab.liveTV) {
                        activeOnly(.liveTV, selection: selection.wrappedValue) { LiveTVView() }
                    } label: {
                        Text("Live TV")
                    }
                }

                Tab(value: AppTab.settings) {
                    activeOnly(.settings, selection: selection.wrappedValue) { SettingsView() }
                } label: {
                    Image(systemName: "gear")
                }
            }
        }

        /// Whether something layered over the tabs owns the screen: tvOS focus is
        /// not clipped by z-order, so the tab bar and the cards behind a plain
        /// overlay would still take presses. The playlist switch is deliberately
        /// absent — it settles in under half a second, and disabling the tabs for
        /// it would move focus and hand it back somewhere else.
        private var blockingOverlayOwnsScreen: Bool {
            router.isMultiViewPresented
                || activeSyncRequest != nil
                || profileManager?.isSwitching == true
        }

        /// Whether Play/Pause may toggle the quick-switch modal right now. Off
        /// while a blocking overlay owns the screen, and off when neither column
        /// would have a focusable row — an empty modal over a disabled tab bar has
        /// nothing to hand focus to, and so nothing to deliver Menu either.
        private var playPauseTogglesQuickSwitch: Bool {
            if router.isQuickSwitchPresented {
                return true
            }
            guard !blockingOverlayOwnsScreen else { return false }
            return !playlists.isEmpty || profileManager?.isReady == true
        }

        /// tvOS `TabView` keeps every *visited* tab's view hierarchy alive, and
        /// each remote press triggers a focus/accessibility responder walk over
        /// the whole window — a device trace showed those walks dominating the
        /// EPG guide's scroll time once Home (hero + card rails) had been
        /// visited. Rendering only the selected tab keeps the walked hierarchy
        /// small; tab-local view state resets on switch, which is the usual
        /// tvOS behaviour anyway (navigation paths live in `DeepLinkRouter`
        /// and survive).
        @ViewBuilder
        private func activeOnly(_ tab: AppTab, selection: AppTab, @ViewBuilder content: () -> some View) -> some View {
            if selection == tab {
                content()
            } else {
                Color.clear
            }
        }
    #else
        private func tabView(selection: Binding<AppTab>) -> some View {
            TabView(selection: selection) {
                if isOn(.home) {
                    Tab("Home", systemImage: "house", value: AppTab.home) {
                        HomeView()
                    }
                }

                if isOn(.movies) {
                    Tab("Movies", systemImage: "film", value: AppTab.movies) {
                        MoviesView()
                    }
                }

                if isOn(.series) {
                    Tab("Series", systemImage: "tv", value: AppTab.series) {
                        SeriesView()
                    }
                }

                if isOn(.liveTV) {
                    Tab("Live TV", systemImage: "antenna.radiowaves.left.and.right", value: AppTab.liveTV) {
                        LiveTVView()
                    }
                }

                // macOS 15's tab bar drops a `role: .search` tab entirely — even
                // with an explicit label (the previous workaround), the search tab
                // never renders, leaving no way to reach Search there. macOS 26
                // renders the role correctly, as do iOS/visionOS 18+, so only
                // macOS 15 falls back to a plain tab and every other system keeps
                // the dedicated search treatment.
                if #unavailable(macOS 26) {
                    Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                        SearchView()
                    }
                } else {
                    Tab(value: AppTab.search, role: .search) {
                        SearchView()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
            }
        }
    #endif

    // MARK: - Deep links

    /// Resolves a `lume://movie/{tmdbId}` / `lume://series/{tmdbId}` link to a
    /// catalog item, switches to the matching tab and pushes its detail screen.
    /// Silently ignores unknown links and titles not present in the catalog
    /// (e.g. a tmdbId that was never synced or enriched).
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        switch link {
        case let .movie(tmdbId):
            guard let movie = resolveMovie(tmdbId: tmdbId) else { return }
            router.selectedTab = .movies
            router.moviesPath = NavigationPath()
            router.moviesPath.append(movie)
        case let .series(tmdbId):
            guard let series = resolveSeries(tmdbId: tmdbId) else { return }
            router.selectedTab = .series
            router.seriesPath = NavigationPath()
            router.seriesPath.append(series)
        case .resume:
            // The Live Activity was tapped. When a player session is already
            // up, foregrounding the app is all that's needed; otherwise reopen
            // the last played stream where it left off.
            guard NowPlayingService.shared.currentMedia == nil,
                  let media = PlaybackResumeStore.load() else { return }
            #if os(macOS)
                MacPlayerWindowRouter.shared.play(media, using: openWindow)
            #else
                resumeMedia = media
            #endif
        case .downloads:
            // The download Live Activity was tapped.
            showsDownloads = true
        }
    }

    /// Finds a movie by `tmdbId`, preferring the active playlist but falling back
    /// to any other playlist's copy. Restricted categories stay hidden for a
    /// child profile.
    private func resolveMovie(tmdbId: Int) -> Movie? {
        let descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.tmdbId == tmdbId })
        let restriction = contentRestriction
        let matches = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { !restriction.hides(categoryID: $0.categoryId) }
        return matches.first { belongsToActivePlaylist($0.id) } ?? matches.first
    }

    private func resolveSeries(tmdbId: Int) -> Series? {
        let descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.tmdbId == tmdbId })
        let restriction = contentRestriction
        let matches = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { !restriction.hides(categoryID: $0.categoryId) }
        return matches.first { belongsToActivePlaylist($0.id) } ?? matches.first
    }

    private func belongsToActivePlaylist(_ id: String) -> Bool {
        guard let activePlaylist = playlists.active(for: selectedPlaylistID) else { return true }
        return id.hasPrefix("\(activePlaylist.id.uuidString)-")
    }

    // MARK: - Automatic sync

    /// Enqueues every due playlist for a blocking, progress-visible sync and
    /// presents the first one. Covers the never-synced first launch (where
    /// `lastSyncDate == nil` makes a playlist due) as well as periodic refreshes.
    private func enqueueDueSyncs(_ candidates: [Playlist]) {
        guard !isUITesting else { return }

        for playlist in candidates where !isQueued(playlist) {
            guard let request = syncRequest(for: playlist) else { continue }
            autoSyncAttempted.insert(playlist.id)
            syncQueue.append(request)
        }
        promoteNextIfIdle()
    }

    private func isQueued(_ playlist: Playlist) -> Bool {
        activeSyncRequest?.id == playlist.id || syncQueue.contains { $0.id == playlist.id }
    }

    private func syncRequest(for playlist: Playlist) -> PlaylistSyncRequest? {
        PlaylistSyncCoverage.bootstrapFromCatalogIfNeeded(
            playlistID: playlist.id,
            context: modelContext
        )
        let missingAreas = PlaylistSyncCoverage.missingEnabledAreas(
            playlistID: playlist.id,
            disabledAreasRaw: disabledAreasRaw
        )
        let isRegularlyDue = AutoSync.shouldSync(
            syncEnabled: playlist.syncEnabled,
            status: playlist.syncStatus,
            lastSyncDate: playlist.lastSyncDate,
            frequency: syncFrequency,
            alreadyStarted: autoSyncAttempted.contains(playlist.id)
        )
        let needsCoverage = !missingAreas.isEmpty && playlist.syncEnabled && playlist.syncStatus != .syncing
        guard isRegularlyDue || needsCoverage else { return nil }

        // A due playlist gets its ordinary refresh. Only the otherwise-current
        // Xtream playlist uses the narrow repair path; m3u and Stalker do not
        // expose independent per-area bulk imports.
        let repairingAreas = !isRegularlyDue && playlist.sourceType == .xtream ? missingAreas : nil
        return PlaylistSyncRequest(playlist: playlist, repairingAreas: repairingAreas)
    }

    /// Presents the next queued playlist's sync cover when none is showing. The
    /// `SyncProgressView` auto-starts the sync and dismisses itself on success;
    /// the cover's `onDismiss` calls back here to advance the queue.
    private func promoteNextIfIdle() {
        guard activeSyncRequest == nil, !syncQueue.isEmpty else { return }
        activeSyncRequest = syncQueue.removeFirst()
    }
}

private struct PlaylistSyncRequest: Identifiable {
    let playlist: Playlist
    let repairingAreas: Set<AppArea>?

    var id: UUID {
        playlist.id
    }
}

private struct AutoSyncTrigger: Hashable {
    let playlistCount: Int
    let activeProfileToken: String
    let disabledAreasRaw: String
}

// MARK: - Downloads sheet presentation

private extension View {
    /// Presents the downloads list as a sheet, in the same navigation + dismiss
    /// chrome Settings gives it. The download Live Activity's tap target, so it
    /// is reachable without disturbing whatever tab the user had open.
    @ViewBuilder
    func downloadsSheet(isPresented: Binding<Bool>) -> some View {
        #if os(tvOS)
            // tvOS has no downloads feature to show.
            self
        #else
            sheet(isPresented: isPresented) {
                NavigationStack {
                    DownloadsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isPresented.wrappedValue = false }
                            }
                        }
                }
                #if os(macOS)
                // A `List` in a frameless macOS sheet collapses to zero
                // height, leaving the sheet rendering as a bare toolbar.
                .frame(minWidth: 480, minHeight: 440)
                #endif
            }
        #endif
    }
}

// MARK: - Sync cover presentation

private extension View {
    /// Presents the auto-sync progress UI as a blocking cover: a full-screen
    /// cover on iOS/tvOS (no swipe-to-dismiss), a sheet on macOS where
    /// `fullScreenCover` is unavailable.
    @ViewBuilder
    func syncCover(item: Binding<PlaylistSyncRequest?>, onDismiss: @escaping () -> Void) -> some View {
        #if os(macOS)
            sheet(item: item, onDismiss: onDismiss) { request in
                SyncProgressView(
                    playlist: request.playlist,
                    autoStart: true,
                    repairingAreas: request.repairingAreas
                )
                .frame(minWidth: 420, minHeight: 480)
            }
        #else
            fullScreenCover(item: item, onDismiss: onDismiss) { request in
                SyncProgressView(
                    playlist: request.playlist,
                    autoStart: true,
                    repairingAreas: request.repairingAreas
                )
            }
        #endif
    }
}

#Preview("No Playlists") {
    MainTabView()
}

#Preview("With Playlists") {
    MainTabView()
        .modelContainer(for: Playlist.self, inMemory: true) { result in
            if case let .success(container) = result {
                let playlist = Playlist(name: "My IPTV", serverURL: "http://example.com:8080", username: "user", password: "pass")
                container.mainContext.insert(playlist)
            }
        }
}

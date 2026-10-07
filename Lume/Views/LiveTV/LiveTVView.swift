//
//  LiveTVView.swift
//  Lume
//
//  Main view for browsing live TV channels. Categories live in an overlay
//  sidebar; channels for the selected category are loaded lazily via @Query.
//

import SwiftData
import SwiftUI

extension LiveTVLayoutMode {
    var label: LocalizedStringKey {
        self == .list ? "List" : "Guide"
    }
}

struct LiveTVView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]
    @Query private var categories: [Category]

    /// Keeps the sidebar's categories from being filtered and sorted on every body
    /// pass — see `LiveTVCategoryMemo`. Whether the two virtual sections appear
    /// is `LiveTVSections`' job; it owns the bounded probes that answer it.
    @State private var categoryMemo = LiveTVCategoryMemo()

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    /// The navigation path lives in `DeepLinkRouter`, so destinations survive
    /// tab unmounting. The local path is only a fallback for previews.
    @Environment(DeepLinkRouter.self) private var selectionRouter: DeepLinkRouter?
    @State private var localPath = NavigationPath()

    private var navigationPath: Binding<NavigationPath> {
        DetailNavigation.pathBinding(in: selectionRouter, at: \.liveTVPath, fallback: $localPath)
    }

    @State private var showingSync = false
    @State private var playingMedia: PlayableMedia?
    @State private var showingSettings = false
    @State private var browse = BrowseSidebarState()
    /// The sections the browse panel lists, as the content last resolved them.
    @State private var browseSections: [LiveTVSection]?
    #if os(tvOS)
        @Environment(DeepLinkRouter.self) private var router
        /// Owns a request whenever the content should take focus deliberately rather
        /// than let the engine pick: after a category change, and on the way
        /// back out of the browse panel.
        @State private var contentFocus = TVContentFocusMachine()
        /// The content focus left when Browse opened. This is a temporary
        /// handoff, not a second copy of the navigation/category selection.
        @State private var browseReturnFocus: TVContentFocusRequest?
    #else
        /// Non-nil while Multi-View is up; carries the channels it opened with,
        /// when it was started from a channel rather than the toolbar.
        @State private var multiViewLaunch: MultiViewLaunch?
    #endif
    @State private var showingPaywall = false
    @State private var premium = PremiumManager.shared

    @AppStorage(LiveTVLayoutMode.storageKey) private var layoutModeRaw: String = LiveTVLayoutMode.list.rawValue

    private var layoutMode: LiveTVLayoutMode {
        LiveTVLayoutMode.resolved(layoutModeRaw)
    }

    /// MainTabView supplies the same active scope as Movies/Series. Query
    /// construction stays separate from category ordering and section probes.
    init(playlistPrefix: String? = nil, restriction: ContentRestriction = ContentRestriction()) {
        _categories = Query(LibraryCategoryQuery.descriptor(
            type: .live, playlistPrefix: playlistPrefix ?? "",
            excludedCategoryIDs: restriction.excludedCategoryIDs
        ))
    }

    /// Guide/List segmented switch shared across platforms.
    private var layoutModePicker: some View {
        Picker("Layout", selection: Binding(
            get: { layoutMode },
            set: { layoutModeRaw = $0.rawValue }
        )) {
            ForEach(LiveTVLayoutMode.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    #if !os(tvOS)
        /// The channel detail area for the selected section, honouring the
        /// current layout mode. tvOS builds its own in `TVLiveTVScreen`.
        private func detail(for section: LiveTVSection) -> some View {
            Group {
                if layoutMode == .guide {
                    EPGGuideView(
                        scope: section.scope,
                        playlistPrefix: playlistPrefix,
                        onPlay: { playChannel($0, scope: section.scope) },
                        onPlayCatchup: { playCatchup($0, programme: EPGSlot($1)) },
                        onStartMultiView: { startMultiView(with: $0) }
                    )
                } else {
                    channelList(for: section)
                }
            }
            .id("\(section.id)-\(layoutModeRaw)")
        }

        private func channelList(for section: LiveTVSection) -> some View {
            ChannelsList(
                scope: section.scope,
                playlistPrefix: playlistPrefix,
                onStartMultiView: { startMultiView(with: $0) },
                onWatchFromStart: { playCatchup($0, programme: $1) },
                onPlay: { playChannel($0, scope: section.scope) }
            )
        }
    #endif

    var body: some View {
        NavigationStack(path: navigationPath) {
            if shouldResolveSections {
                // The rail resolves in a child view: gating the two virtual
                // sections is a pair of playlist-scoped `LIMIT 1` probes, and
                // a `@Query` carries that scope only when its descriptor is
                // built in an `init` the active playlist reaches.
                LiveTVSections(
                    playlistPrefix: playlistPrefix,
                    restriction: restriction,
                    categorySections: categorySections
                ) { sections in
                    rootContent(sections: sections)
                }
            } else {
                rootContent(sections: nil)
            }
        }
        // Above the stack, so the panel covers the navigation bar too — the
        // bar draws over anything inside the stack.
        .overlay(alignment: .leading) {
            if let sections = browseSections {
                LiveTVBrowseSidebar(
                    state: browse,
                    sections: sections,
                    onSelect: selectSection,
                    onReturnToContent: browseReturnHandler
                )
            }
        }
        .onChange(of: playlistPrefix) { _, _ in
            // A pushed browse screen must not survive a playlist change just
            // because its hub root's task is currently off-screen.
            navigationPath.wrappedValue = NavigationPath()
        }
        #if os(tvOS)
        .onChange(of: navigationPath.wrappedValue.isEmpty, initial: true) { _, isAtRoot in
            guard isAtRoot else { return }
            contentFocus.cancel()
            browseReturnFocus = nil
        }
        .onChange(of: playlistPrefix) { _, _ in contentFocus.cancel() }
        .onChange(of: restriction.visibilityToken) { _, _ in contentFocus.cancel() }
        .onChange(of: layoutModeRaw) { _, _ in contentFocus.cancel() }
        .onDisappear { contentFocus.cancel() }
        #endif
    }

    /// Attaches the browse panel to the same navigation-content root as Movies
    /// and Series. Attaching it to `layout(for:)` starts it below Live TV's own
    /// list/guide controls instead of allowing its safe-area escape to cover the
    /// toolbar consistently.
    @ViewBuilder
    private func rootContent(sections: [LiveTVSection]?) -> some View {
        // No title, like Home: the tab names the area.
        contentState(sections: sections)
        #if os(iOS)
            // Keep the compact content controls visually attached to the
            // navigation bar when the channel list is overscrolled.
            .navigationBarTitleDisplayMode(.inline)
        #endif
            // Match Movies and Series modifier order. On macOS all three use
            // the navigation toolbar placement; changing this order lets the
            // native toolbar reverse the profile and browse controls as the
            // visible tab set changes.
            .profileMenuToolbar()
            .libraryToolbar(config: LibraryToolbarConfiguration(
                playlists: playlists,
                selectedPlaylistID: $selectedPlaylistID,
                showingSync: $showingSync,
                showingSettings: $showingSettings,
                activePlaylist: activePlaylist
            ))
            .browseSidebarToolbar(
                isPresented: $browse.isPresented,
                isEnabled: sections?.isEmpty == false
            )
            .navigationDestination(for: LiveTVSection.self) { section in
                layout(displayed: section)
                    .browseSidebarToolbar(isPresented: $browse.isPresented, isEnabled: sections?.isEmpty == false)
            }
            // Hands the sections up to the panel, which sits above the stack.
            .onChange(of: sections?.map(\.id), initial: true) { _, _ in browseSections = sections }
        #if os(iOS) || os(tvOS)
            .fullScreenCover(item: $playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
        #endif
        #if os(iOS)
        .fullScreenCover(item: $multiViewLaunch) { launch in
            MultiViewScreen(seed: launch.seed)
        }
        #endif
        .paywall(isPresented: $showingPaywall, highlight: .multiView)
    }

    private func contentState(sections: [LiveTVSection]?) -> some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Add a playlist in Settings to start watching live TV")
                )
            } else if let sections, !sections.isEmpty {
                LiveTVHubView(
                    playlistPrefix: playlistPrefix, syncedAt: activePlaylist?.lastSyncDate,
                    onOpenBrowse: { browse.isPresented = true },
                    onOpenGuide: {
                        layoutModeRaw = LiveTVLayoutMode.guide.rawValue
                        if let section = sections.first { selectSection(section) }
                    },
                    onPlay: playHubChannel,
                    onWatchFromStart: { playHubCatchup($0, programme: $1) },
                    onStartMultiView: startHubMultiView
                )
            } else {
                LiveTVEmptyState(sourceType: activePlaylist?.knownSourceType, playlistPrefix: playlistPrefix, restriction: restriction)
            }
        }
    }

    private var shouldResolveSections: Bool {
        !playlists.isEmpty && !playlistPrefix.isEmpty
    }

    // MARK: - Platform-specific layouts

    /// This platform's browse layout for the resolved sections. The displayed
    /// section resolves here once per render.
    private func layout(displayed: LiveTVSection?) -> some View {
        Group {
            #if os(tvOS)
                tvOSLayout(displayed: displayed)
            #else
                contentLayout(displayed: displayed)
            #endif
        }
    }

    #if !os(tvOS)
        private func contentLayout(displayed: LiveTVSection?) -> some View {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    layoutModePicker
                        .frame(maxWidth: 240)

                    Spacer(minLength: 0)

                    Button {
                        openMultiView()
                    } label: {
                        Label("Multi-View", systemImage: "rectangle.split.2x2")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)

                Divider()

                if let displayed {
                    detail(for: displayed)
                } else {
                    ContentUnavailableView(
                        "Select a Category",
                        systemImage: "list.bullet",
                        description: Text("Choose a category from the sidebar")
                    )
                }
                BrowseCategoriesButton(isPresented: $browse.isPresented)
            }
        }
    #endif

    #if os(tvOS)
        private func tvOSLayout(displayed: LiveTVSection?) -> some View {
            TVLiveTVScreen(
                displayedSection: displayed,
                layoutModeRaw: $layoutModeRaw,
                onOpenBrowse: { openBrowse(from: $0, section: displayed) },
                onPlay: { playChannel($0, scope: displayed?.scope) },
                onPlayCatchup: { playCatchup($0, programme: $1) },
                onOpenMultiView: { openMultiView() },
                onStartMultiView: { startMultiView(with: $0) },
                playlistPrefix: playlistPrefix,
                sourceType: activePlaylist?.knownSourceType,
                contentFocusRequest: contentFocus.request,
                onDidClaimFocus: { contentFocus.didClaim($0) }
            )
        }
    #endif

    private func selectSection(_ section: LiveTVSection) {
        // Browse is a destination, like Movies/Series categories, never a
        // replacement for the hub. Sidebar changes replace this one level.
        navigationPath.wrappedValue = NavigationPath([section])
        #if os(tvOS)
            // A different category is a different list: nothing to return to,
            // so the new one takes focus at the top.
            browseReturnFocus = nil
            requestContentFocus(for: section)
        #endif
    }

    #if os(tvOS)
        /// Opens the browse panel, remembering the channel focus is leaving.
        private func openBrowse(from channelID: String?, section: LiveTVSection?) {
            contentFocus.cancel()
            browseReturnFocus = section.map { TVContentFocusRequest(scope: focusScope(for: $0), channelID: channelID) }
            browse.isPresented = true
        }

        /// Leaving the panel without picking a category: the list is unchanged,
        /// so focus goes back to the channel it came from.
        private func returnFromBrowse() {
            guard !navigationPath.wrappedValue.isEmpty else { return }
            guard let target = browseReturnFocus,
                  target.scope.playlistPrefix == playlistPrefix,
                  target.scope.visibilityToken == restriction.visibilityToken else { return }
            contentFocus.requestFocus(in: target.scope, channelID: target.channelID)
            browseReturnFocus = nil
        }

        private func requestContentFocus(for section: LiveTVSection, channelID: String? = nil) {
            contentFocus.requestFocus(in: focusScope(for: section), channelID: channelID)
        }

        private func focusScope(for section: LiveTVSection) -> TVContentFocusRequest.Scope {
            TVContentFocusRequest.Scope(playlistPrefix: playlistPrefix, channelScope: section.scope, visibilityToken: restriction.visibilityToken)
        }
    #endif

    /// tvOS returns focus to the channel the panel was opened from; elsewhere
    /// the panel closes with a button or a tap and there is no focus to place.
    private var browseReturnHandler: (() -> Void)? {
        #if os(tvOS)
            returnFromBrowse
        #else
            nil
        #endif
    }

    /// The playlist whose content is currently shown, resolved from the global
    /// selection. Falls back to the first playlist until the user picks one.
    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// The id prefix every Category / LiveStream of the active playlist shares.
    private var playlistPrefix: String {
        activePlaylist?.contentIDPrefix ?? ""
    }

    /// The rail's category entries: the active playlist's live categories this
    /// viewer may see, in provider/custom order. SQL already selects the active
    /// playlist and exclusions; the memo retains ordering and a defensive
    /// visibility check without sorting again on unrelated body passes.
    private var categorySections: [LiveTVSection] {
        categoryMemo.sections(
            categories: categories,
            playlistPrefix: playlistPrefix,
            sort: .playlist,
            restriction: restriction
        )
    }

    /// `scope` is the section the channel was picked from; it travels with the
    /// media so in-player channel surfing stays inside that list.
    private func playChannel(_ stream: LiveStream, scope: LiveChannelScope?) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist, scope: scope) else { return }
        present(media)
    }

    /// Resolve only the selected row onto the main context. Hub loading and
    /// EPG matching pass values across actors, never managed catalog objects.
    private func hubStream(_ id: String) -> LiveStream? {
        LiveTVHubSelection.stream(id, prefix: playlistPrefix, restriction: restriction, in: modelContext)
    }

    private func playHubChannel(_ id: String, scope: LiveChannelScope?) {
        if let stream = hubStream(id) { playChannel(stream, scope: scope) }
    }

    private func playHubCatchup(_ id: String, programme: EPGSlot) {
        guard let stream = hubStream(id), stream.restartableProgramme(programme, now: .now) != nil else { return }
        playCatchup(stream, programme: programme)
    }

    private func startHubMultiView(_ id: String) {
        if let stream = hubStream(id) { startMultiView(with: stream) }
    }

    /// Replays a programme from the channel's catch-up archive — a finished one
    /// picked in the guide, or the one on air restarted from its beginning (the
    /// guide's detail sheet and a list row's "Watch from Start"). Catch-up has
    /// no surf scope, whichever list it came from.
    private func playCatchup(_ stream: LiveStream, programme: EPGSlot) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.catchup(
                  stream: stream,
                  playlist: playlist,
                  programTitle: programme.title,
                  start: programme.start,
                  end: programme.end
              ) else { return }
        present(media)
    }

    /// Opens Multi-View on a channel picked from the list, so the grid starts
    /// with something playing rather than two empty tiles.
    private func startMultiView(with stream: LiveStream) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist)
        else {
            return
        }
        openMultiView(seed: [media])
    }

    /// Opens Multi-View, or the paywall when the viewer isn't on Lume Pro.
    private func openMultiView(seed: [PlayableMedia] = []) {
        guard premium.isPremium else {
            showingPaywall = true
            return
        }
        #if os(macOS)
            // The window is a singleton, so it cannot be built around a launch:
            // hand the channels over and let the grid adopt them on appear.
            MultiViewLaunchQueue.shared.pending = seed
            openWindow(id: "multiview")
        #elseif os(tvOS)
            // Presented by `MainTabView`, above the tab bar — see the router.
            router.multiViewLaunch = MultiViewLaunch(seed: seed)
        #else
            multiViewLaunch = MultiViewLaunch(seed: seed)
        #endif
    }

    private func present(_ media: PlayableMedia) {
        if ExternalPlayback.open(media) { return }
        #if os(macOS)
            MacPlayerWindowRouter.shared.play(media, using: openWindow)
        #else
            playingMedia = media
        #endif
    }
}

#Preview("Empty") {
    LiveTVView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    LiveTVView()
        .modelContainer(previewContainer())
}

#Preview("No Playlists") {
    LiveTVView()
}

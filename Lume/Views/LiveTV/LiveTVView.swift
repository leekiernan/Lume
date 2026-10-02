//
//  LiveTVView.swift
//  Lume
//
//  Main view for browsing live TV channels. Categories live in an overlay
//  sidebar; channels for the selected category are loaded lazily via @Query.
//

import SwiftData
import SwiftUI

/// How the Live TV detail area presents channels: a scannable list (default) or
/// the EPG timeline grid. Persisted across launches.
enum LiveTVLayoutMode: String, CaseIterable, Identifiable {
    case list
    case guide

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        self == .list ? "List" : "Guide"
    }

    var systemImage: String {
        self == .list ? "list.bullet" : "tablecells"
    }

    static let storageKey = "lume.liveTV.layoutMode"
}

struct LiveTVView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "live" && $0.isHidden == false })
    private var categories: [Category]

    /// Keeps the sidebar's categories from being filtered and sorted on every body
    /// pass — see `LiveTVCategoryMemo`. Whether the two virtual sections appear
    /// is `LiveTVSections`' job; it owns the bounded probes that answer it.
    @State private var categoryMemo = LiveTVCategoryMemo()

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    /// The selection lives in `DeepLinkRouter`, so it survives the tab being
    /// unmounted (`IdleUnmountingTab`, or a tvOS tab switch); these local copies
    /// stand in only without a router (previews).
    @Environment(DeepLinkRouter.self) private var selectionRouter: DeepLinkRouter?
    @State private var localSection: LiveTVSection?
    @State private var localSeededPrefix: String?

    private var selectedSection: LiveTVSection? {
        get { selectionRouter?.liveTVSection ?? localSection }
        nonmutating set {
            if let selectionRouter { selectionRouter.liveTVSection = newValue } else { localSection = newValue }
        }
    }

    /// The playlist `selectedSection` was last seeded for — see `seedSelection`.
    private var seededPrefix: String? {
        get { selectionRouter?.liveTVSeededPrefix ?? localSeededPrefix }
        nonmutating set {
            if let selectionRouter { selectionRouter.liveTVSeededPrefix = newValue } else { localSeededPrefix = newValue }
        }
    }

    @State private var showingSync = false
    @State private var playingMedia: PlayableMedia?
    @State private var showingSettings = false
    @State private var showingBrowse = false
    /// The sections the browse panel lists, as the content last resolved them.
    @State private var browseSections: [LiveTVSection]?
    #if os(tvOS)
        @Environment(DeepLinkRouter.self) private var router
        /// Bumped whenever the content should take focus deliberately rather
        /// than let the engine pick: after a category change, and on the way
        /// back out of the browse panel.
        @State private var contentFocusToken = 0
        /// Where that focus should land — the channel the panel was opened
        /// from, or nil for the top of the list.
        @State private var contentFocusTarget: String?
        /// The channel focus left when the browse panel was opened, so closing
        /// it without picking anything puts the viewer back where they were.
        @State private var browseReturnChannelID: String?
    #else
        /// Non-nil while Multi-View is up; carries the channels it opened with,
        /// when it was started from a channel rather than the toolbar.
        @State private var multiViewLaunch: MultiViewLaunch?
    #endif
    @State private var showingPaywall = false
    @State private var premium = PremiumManager.shared

    @AppStorage(SortStorageKey.liveCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.liveContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @AppStorage(LiveTVLayoutMode.storageKey) private var layoutModeRaw: String = LiveTVLayoutMode.list.rawValue

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    private var layoutMode: LiveTVLayoutMode {
        LiveTVLayoutMode(rawValue: layoutModeRaw) ?? .list
    }

    /// Guide/List segmented switch shared across platforms.
    private var layoutModePicker: some View {
        Picker("Layout", selection: $layoutModeRaw) {
            ForEach(LiveTVLayoutMode.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// The channel detail area for the selected section, honouring the current
    /// layout mode. Shared by every platform's layout.
    private func detail(for section: LiveTVSection) -> some View {
        Group {
            if layoutMode == .guide {
                EPGGuideView(
                    scope: section.scope,
                    playlistPrefix: playlistPrefix,
                    sort: contentSort,
                    onPlay: { playChannel($0, scope: section.scope) },
                    onPlayCatchup: { playCatchup($0, programme: EPGSlot($1)) },
                    onStartMultiView: { startMultiView(with: $0) }
                )
            } else {
                channelList(for: section)
            }
        }
        .id("\(section.id)-\(contentSort.rawValue)-\(layoutModeRaw)")
    }

    @ViewBuilder
    private func channelList(for section: LiveTVSection) -> some View {
        #if os(tvOS)
            TVChannelsList(
                scope: section.scope,
                playlistPrefix: playlistPrefix,
                sort: contentSort,
                onLeadingLeft: { openBrowse(from: $0) },
                sourceType: activePlaylist?.knownSourceType,
                onStartMultiView: { startMultiView(with: $0) },
                onWatchFromStart: { playCatchup($0, programme: $1) },
                onPlay: { playChannel($0, scope: section.scope) }
            )
            .frame(maxWidth: .infinity)
        #else
            ChannelsList(
                scope: section.scope,
                playlistPrefix: playlistPrefix,
                sort: contentSort,
                onStartMultiView: { startMultiView(with: $0) },
                onWatchFromStart: { playCatchup($0, programme: $1) },
                onPlay: { playChannel($0, scope: section.scope) }
            )
        #endif
    }

    var body: some View {
        NavigationStack {
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
                    isPresented: $showingBrowse,
                    sections: sections,
                    selectedSection: displayedSection(in: sections),
                    onSelect: selectSection,
                    onReturnToContent: browseReturnHandler
                )
            }
        }
    }

    /// Attaches the browse panel to the same navigation-content root as Movies
    /// and Series. Attaching it to `layout(for:)` starts it below Live TV's own
    /// list/guide controls instead of allowing its safe-area escape to cover the
    /// toolbar consistently.
    @ViewBuilder
    private func rootContent(sections: [LiveTVSection]?) -> some View {
        contentState(sections: sections)
            .platformNavigationTitle("Live TV")
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
                categorySortRaw: $categorySortRaw,
                contentSortRaw: $contentSortRaw,
                showingSync: $showingSync,
                showingSettings: $showingSettings,
                activePlaylist: activePlaylist
            ))
            .browseSidebarToolbar(
                isPresented: $showingBrowse,
                isEnabled: !playlists.isEmpty && !categories.isEmpty
            )
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
            } else if categories.isEmpty || sourceHasNoLiveChannels {
                VStack(spacing: 20) {
                    LiveTVEmptyState(sourceType: activePlaylist?.knownSourceType)
                }
            } else if let sections {
                layout(for: sections)
                    .task(id: playlistPrefix) { seedSelection(from: sections) }
            }
        }
    }

    private var shouldResolveSections: Bool {
        !playlists.isEmpty && !categories.isEmpty && !sourceHasNoLiveChannels
    }

    // MARK: - Platform-specific layouts

    /// This platform's browse layout for the resolved sections. The displayed
    /// section resolves here once per render.
    @ViewBuilder
    private func layout(for sections: [LiveTVSection]) -> some View {
        let displayed = displayedSection(in: sections)
        VStack(spacing: 0) {
            #if os(tvOS)
                tvOSLayout(displayed: displayed)
            #else
                contentLayout(displayed: displayed)
            #endif

            BrowseCategoriesButton(isPresented: $showingBrowse)
                .padding(.bottom, PosterCardMetrics.sectionVerticalPadding)
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
            }
        }
    #endif

    #if os(tvOS)
        private func tvOSLayout(displayed: LiveTVSection?) -> some View {
            TVLiveTVScreen(
                displayedSection: displayed,
                layoutModeRaw: $layoutModeRaw,
                contentSort: contentSort,
                onOpenBrowse: { openBrowse(from: $0) },
                onPlay: { playChannel($0, scope: displayed?.scope) },
                onPlayCatchup: { playCatchup($0, programme: $1) },
                onOpenMultiView: { openMultiView() },
                onStartMultiView: { startMultiView(with: $0) },
                playlistPrefix: playlistPrefix,
                sourceType: activePlaylist?.knownSourceType,
                contentFocusToken: $contentFocusToken,
                contentFocusTarget: contentFocusTarget
            )
        }
    #endif

    private func selectSection(_ section: LiveTVSection) {
        selectedSection = section
        showingBrowse = false
        #if os(tvOS)
            // A different category is a different list: nothing to return to,
            // so the new one takes focus at the top.
            contentFocusTarget = nil
            contentFocusToken += 1
        #endif
    }

    #if os(tvOS)
        /// Opens the browse panel, remembering the channel focus is leaving.
        private func openBrowse(from channelID: String?) {
            browseReturnChannelID = channelID
            showingBrowse = true
        }

        /// Leaving the panel without picking a category: the list is unchanged,
        /// so focus goes back to the channel it came from.
        private func returnFromBrowse() {
            contentFocusTarget = browseReturnChannelID
            contentFocusToken += 1
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

    /// A WebDAV share carries no live channels, so its rail stays empty even
    /// when another playlist has live categories — the unscoped `categories`
    /// query cannot see that on its own. Same for the media servers, whose
    /// Live TV tuner APIs are not synced.
    private var sourceHasNoLiveChannels: Bool {
        activePlaylist?.knownSourceType.map { !$0.canCarryLiveChannels } == true && categorySections.isEmpty
    }

    /// The id prefix every Category / LiveStream of the active playlist shares.
    private var playlistPrefix: String {
        activePlaylist.map { "\($0.id.uuidString)-" } ?? ""
    }

    /// The rail's category entries: the active playlist's live categories this
    /// viewer may see, in the chosen order. The `@Query` fetches every playlist's
    /// categories (SwiftData can't parameterize a `@Query` on view state), so the
    /// isolation by playlist-prefixed `id` — and the sort — happen here, memoized
    /// so a body pass that changed nothing about them costs a key comparison.
    private var categorySections: [LiveTVSection] {
        categoryMemo.sections(
            categories: categories,
            playlistPrefix: playlistPrefix,
            sort: categorySort,
            restriction: restriction
        )
    }

    /// Points the rail at its first section. On first appearance that only means
    /// seeding an empty selection; on a playlist switch it resets unconditionally,
    /// because the previous selection belonged to the playlist that just went
    /// away — the two moments the removed `.task` / `.onChange(of:)` pair covered.
    /// Anything narrower (a category hidden in Content Management, the last
    /// favorite removed) is left to `displayedSection(in:)`, as before.
    private func seedSelection(from sections: [LiveTVSection]) {
        if seededPrefix != nil, seededPrefix != playlistPrefix {
            selectedSection = sections.first
        } else if selectedSection == nil {
            selectedSection = sections.first
        }
        seededPrefix = playlistPrefix
    }

    /// The section to render in the detail pane. Normally the user's selection,
    /// but if that section just disappeared (a category hidden in Content
    /// Management, or the last favorite removed) fall back to the first available
    /// one rather than keep showing stale content.
    private func displayedSection(in sections: [LiveTVSection]) -> LiveTVSection? {
        guard let selectedSection else { return sections.first }
        return sections.contains { $0.id == selectedSection.id }
            ? selectedSection
            : sections.first
    }

    /// `scope` is the section the channel was picked from; it travels with the
    /// media so in-player channel surfing stays inside that list.
    private func playChannel(_ stream: LiveStream, scope: LiveChannelScope?) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist, scope: scope) else { return }
        present(media)
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

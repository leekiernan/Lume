//
//  HomeView.swift
//  Lume
//
//  Default landing screen. Shows Recently Watched, Favorites, For You (opt-in
//  Pro recommendations), Trending Movies/Series and the Trakt watchlist. Which
//  rows appear and their order are user-configurable (Settings › Layout › Home,
//  see HomeLayoutSettings); each row only renders when it has content.
//

import SwiftData
import SwiftUI

struct HomeView: View {
    @Namespace private var animationNamespace
    // Several members below are `internal` (not `private`) so the "For You"
    // row's loading in `HomeView+ForYou.swift` can drive them.
    @Environment(\.modelContext) var modelContext
    @Environment(\.contentRestriction) var restriction
    #if os(macOS)
        /// Not `private`: read by the HomeView+Playback extension (separate file).
        @Environment(\.openWindow) var openWindow
    #endif

    @Query var playlists: [Playlist]
    @AppStorage(PlaylistSelectionStore.key) var selectedPlaylistID: String = ""
    @AppStorage(SortStorageKey.movieCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    // Recently watched (capped — watch history is naturally bounded).
    @Query var watchedMovies: [Movie]
    @Query var watchedSeries: [Series]
    @Query private var watchedStreams: [LiveStream]

    // Favorites.
    @Query var favoriteMovies: [Movie]
    @Query var favoriteSeries: [Series]
    @Query private var favoriteStreams: [LiveStream]

    /// The remote-backed rows (trending, Trakt watchlist, custom lists), shared
    /// with the Movies and Series pages — see `SectionFeed`.
    @State private var feed = SectionFeed(surface: .home)
    /// Resume fractions for partially-watched series, keyed by series id and
    /// resolved off the main thread — see `SeriesResumeLoader`.
    @State private var seriesResume: [String: Double] = [:]
    @AppStorage(RecommendationSettings.enabledKey) var recommendationsEnabled = RecommendationSettings.enabledDefault
    /// The user's chosen Home row order (Settings › Layout › Home). Falls back to
    /// the surface's default order until they reorder.
    @AppStorage(HomeLayoutSettings.sectionOrderKey(.home)) private var sectionOrderRaw = ""
    /// Sections the user switched off (Settings › Layout › Home). "For You" is
    /// gated by `recommendationsEnabled` instead — see `HomeLayoutSettings`.
    @AppStorage(HomeLayoutSettings.disabledSectionsKey(.home)) var disabledSectionsRaw = ""
    /// The user's custom list-backed rows (Settings › Layout › Home › Add Section).
    @AppStorage(CustomHomeSections.storageKey(.home)) private var customSectionsRaw = ""
    /// Which row Home shows as its hero, and whether its starting hero has been
    /// created yet — see `CustomHomeSections.seedingDefaultHero`.
    @AppStorage(HomeLayoutSettings.heroSectionKey(.home)) var heroSectionRaw = ""
    @AppStorage(HomeLayoutSettings.heroSeededKey(.home)) private var heroSeeded = false
    /// Device-local pointer to one already-cached backdrop, used while the
    /// promoted section resolves on a cold launch. See `HeroWarmStartState`.
    @State var heroWarmStart = HeroWarmStartState(surface: .home)
    /// Areas switched off for this profile (Settings › Library). Live TV is the
    /// one that reaches Home: its channels sit inside the mixed rows below.
    @AppStorage(AppAreaSettings.disabledAreasKey) private var disabledAreasRaw = ""
    /// Bumped by the DEBUG "Recalculate" action in Settings (always 0 otherwise);
    /// part of the task id so the row recomputes on demand.
    @AppStorage(RecommendationSettings.manualRecalculationKey) var recommendationsRecalcToken = 0
    @State var recommendations: [HomeMediaItem] = []
    /// False until the first recommendations pass completes, so the row can show
    /// a progress placeholder rather than an empty state on launch.
    @State var recommendationsLoaded = false
    @State private var trakt = TraktService.shared
    /// "For You" is a Lume Pro feature; observed so the row appears/disappears
    /// when entitlement changes.
    @State var premium = PremiumManager.shared
    // Observed so the For You row defers its (potentially heavy) recompute while
    // the device is busy syncing — and retries automatically once it isn't.
    @State var indexing = ContentIndexingService.shared
    @State var epgSync = EPGSyncService.shared
    /// Observed for the Home empty-state check, which mirrors the Sports rail.
    @State var sportsFollows = SportsFollowService.shared
    @State var sportsStore = SportsStore.shared
    /// Not `private`: read by the HomeView+Playback extension (separate file).
    @State var playingMedia: PlayableMedia?
    @State private var showingSync = false
    @State private var showingSettings = false
    /// Shown when a channel's "Start Multi-View" is picked without Lume Pro.
    /// Not `private`: read by the HomeView+Playback extension (separate file).
    @State var showingPaywall = false
    #if os(tvOS)
        /// Not `private`: read by the HomeView+Playback extension (separate file).
        @Environment(DeepLinkRouter.self) var router
    #else
        /// Non-nil while Multi-View is up; carries the channel it opened with.
        /// Not `private`: read by the HomeView+Playback extension (separate file).
        @State var multiViewLaunch: MultiViewLaunch?
    #endif

    #if os(tvOS)
        /// Hero selected on the immersive home. Drives navigation
        /// programmatically: the hero surface is a stable Button (not a
        /// NavigationLink) so paging the carousel never changes its identity.
        @State private var selectedHero: HeroItem?
    #endif

    init(playlistPrefix: String? = nil, restriction queryRestriction: ContentRestriction = ContentRestriction()) {
        // The scope and visibility checks must be part of each SQL predicate,
        // before its fetch limit. Applying them to the capped result in Swift
        // lets another playlist (or hidden categories) consume every slot and
        // makes a populated Home row appear empty.
        let prefix = playlistPrefix ?? ""
        let excludedCategoryIDs = queryRestriction.excludedCategoryIDs
        _watchedMovies = Query(HomeQuery.watchedMovies(
            playlistPrefix: prefix,
            excludedCategoryIDs: excludedCategoryIDs
        ))
        _watchedSeries = Query(HomeQuery.watchedSeries(
            playlistPrefix: prefix,
            excludedCategoryIDs: excludedCategoryIDs
        ))
        _watchedStreams = Query(HomeQuery.watchedStreams(
            playlistPrefix: prefix,
            excludedCategoryIDs: excludedCategoryIDs
        ))
        _favoriteMovies = Query(HomeQuery.favoriteMovies(
            playlistPrefix: prefix,
            excludedCategoryIDs: excludedCategoryIDs
        ))
        _favoriteSeries = Query(HomeQuery.favoriteSeries(
            playlistPrefix: prefix,
            excludedCategoryIDs: excludedCategoryIDs
        ))
        _favoriteStreams = Query(HomeQuery.favoriteStreams(
            playlistPrefix: prefix,
            excludedCategoryIDs: excludedCategoryIDs
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "house",
                        description: Text("Add a playlist in Settings to get started")
                    )
                } else if isEmpty {
                    ContentUnavailableView(
                        "Nothing Here Yet",
                        systemImage: "house",
                        description: Text("Watch something or mark titles as favorites and they'll show up here.")
                    )
                } else {
                    #if os(tvOS)
                        // Immersive Apple TV-style home: full-screen backdrop,
                        // teasing first row, fold-snapping scroll. Lives in
                        // `TVHomeScreen.swift`.
                        TVHomeScreen(
                            heroItems: feed.heroItems,
                            reservesHero: feed.heroState.reservesSpace,
                            warmStartBackdropURL: heroWarmStartBackdropURL,
                            onSelectHero: { selectedHero = $0 },
                            rows: { homeRows }
                        )
                        .tvQuickSwitchHint(interacted: selectedHero != nil)
                    #else
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: PosterCardMetrics.sectionSpacing) {
                                if !feed.heroItems.isEmpty {
                                    HomeHeroCarousel(items: feed.heroItems)
                                } else if feed.heroState.reservesSpace {
                                    HomeHeroWarmStart(backdropURL: heroWarmStartBackdropURL)
                                }
                                homeRows
                            }
                            // The hero fills the top inset itself when it's
                            // showing; without one, Home takes the same inset as
                            // the Movies and Series pages.
                            .padding(.top, feed.heroState.reservesSpace ? 0 : PosterCardMetrics.sectionVerticalPadding)
                            .padding(.bottom, PosterCardMetrics.sectionVerticalPadding)
                        }
                        .browseActivity()
                        .scrollIndicators(.hidden)
                        // Only let content run under the nav bar when the hero
                        // backdrop is there to fill it; otherwise the first row
                        // would sit hidden behind the bar.
                        .ignoresSafeArea(edges: feed.heroState.reservesSpace ? .top : [])
                    #endif
                }
            }
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
            .navigationDestination(for: Movie.self) { movie in
                MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: movie.id, in: animationNamespace))
                #endif
            }
            .navigationDestination(for: Series.self) { series in
                SeriesDetailView(series: series, animationNamespace: animationNamespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: series.id, in: animationNamespace))
                #endif
            }
            .navigationDestination(for: SectionCollectionSelection.self) { selection in
                SectionCollectionView(
                    selection: selection,
                    feed: feed,
                    animationNamespace: animationNamespace
                )
            }
            #if os(tvOS)
            .navigationDestination(item: $selectedHero) { hero in
                if let movie = hero.movie {
                    MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                } else if let series = hero.series {
                    SeriesDetailView(series: series, animationNamespace: animationNamespace)
                }
            }
            #endif
            .task(id: trendingKey) {
                feed.heroRef = heroRef
                feed.update(context: feedContext)
                await feed.loadTrending(cacheKey: trendingKey)
            }
            .task(id: watchlistKey) {
                feed.heroRef = heroRef
                feed.update(context: feedContext)
                await feed.loadWatchlist(cacheKey: watchlistKey)
            }
            .task(id: recommendationsKey) {
                await loadRecommendations()
            }
            .task(id: customSectionsKey) {
                seedDefaultHeroIfNeeded()
                feed.heroRef = heroRef
                feed.update(context: feedContext)
                await feed.loadCustomSections(cacheKey: customSectionsCacheKey, sections: visibleCustomSections)
            }
            .task(id: seriesResumeKey) {
                await loadSeriesResume()
            }
            .onChange(of: feed.heroItems.first?.imageURL, initial: true) { _, backdropURL in
                rememberHeroWarmStart(backdropURL)
            }
            .task(id: sportsWarmKey) {
                warmSports()
            }
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
    }

    /// The horizontal rails, shared by the iOS/macOS scroll layout and the tvOS
    /// immersive home. Rows render in the user's chosen order (Settings › Layout ›
    /// Home); each only appears when it has content.
    private var homeRows: some View {
        ForEach(HomeLayoutSettings.resolve(
            orderRaw: sectionOrderRaw, custom: customSections, surface: .home,
            liveTVEnabled: AppAreaSettings.isEnabled(.liveTV, disabledRaw: disabledAreasRaw)
        )) { ref in
            homeRow(for: ref)
        }
    }

    @ViewBuilder
    private func homeRow(for ref: HomeSectionRef) -> some View {
        switch ref {
        case let .builtin(section):
            builtinRow(for: section)
        case let .custom(id):
            // A custom row's header is the user's own text, so it goes through
            // verbatim; the items are resolved in `HomeView+CustomSections`.
            // A promoted row is the hero, so it never also draws as a row.
            if ref != heroRef,
               let section = customSections.first(where: { $0.id == id }),
               HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
            {
                rail(Text(verbatim: section.title), feed.items(for: ref), section: ref, title: section.title)
            }
        }
    }

    @ViewBuilder
    private func builtinRow(for section: HomeSection) -> some View {
        if isSectionEnabled(section), .builtin(section) != heroRef {
            switch section {
            case .recentlyWatched:
                rail(Text("Recently Watched"), recentlyWatched, onRemove: removeFromRecentlyWatched)
            case .favorites:
                rail(Text("Favorites"), favorites)
            case .forYou:
                ForYouRow(
                    items: recommendations,
                    seriesResume: seriesResume,
                    isLoading: !recommendationsLoaded,
                    onPlayLive: playChannel,
                    onVote: vote,
                    animationNamespace: animationNamespace
                )
            case .trendingMovies:
                rail(
                    Text("Trending Movies"), feed.items(for: .builtin(section)),
                    section: .builtin(section), title: String(localized: "Trending Movies")
                )
            case .trendingSeries:
                rail(
                    Text("Trending Series"), feed.items(for: .builtin(section)),
                    section: .builtin(section), title: String(localized: "Trending Series")
                )
            case .traktWatchlist:
                rail(
                    Text("From Your Trakt Watchlist"), feed.items(for: .builtin(section)),
                    section: .builtin(section), title: String(localized: "From Your Trakt Watchlist")
                )
            case .sports:
                SportsHomeRail(isSyncBusy: isSyncBusy)
            case .recentlyAdded:
                // Movies/Series only — `HomeSection.cases(for: .home)` never
                // yields it, so Home has no row to draw.
                EmptyView()
            }
        }
    }

    /// Whether `section` should render. "For You" follows the recommendations
    /// opt-in (which also gates its recompute); Sports additionally requires
    /// Live TV, since it matches fixtures to channels in the EPG and has
    /// nothing to show — or sync — once that's off for the profile; the rest
    /// follow the user's per-section switches.
    func isSectionEnabled(_ section: HomeSection) -> Bool {
        switch section {
        case .forYou:
            recommendationsEnabled && premium.isPremium
        case .sports:
            AppAreaSettings.isEnabled(.liveTV, disabledRaw: disabledAreasRaw)
                && HomeLayoutSettings.isEnabled(.builtin(section), disabledRaw: disabledSectionsRaw)
        default:
            HomeLayoutSettings.isEnabled(.builtin(section), disabledRaw: disabledSectionsRaw)
        }
    }

    /// Identity of the trending/hero load, and the key its session memo is
    /// stored under. Includes the visibility token so hiding a category in
    /// Content Management reloads the rows instead of replaying a cached list
    /// that was matched against the whole catalog.
    var trendingKey: String {
        let synced = activePlaylist?.lastSyncDate?.timeIntervalSince1970 ?? 0
        return "\(playlists.count)-\(selectedPlaylistID)-\(synced)-\(restriction.visibilityToken)"
    }

    var watchlistKey: String {
        "watchlist-\(trakt.username ?? "disconnected")-\(trendingKey)"
    }

    /// Identity of the custom-section load. Shares the trending key's playlist /
    /// sync / visibility inputs — the match is against the same catalog — plus a
    /// signature of the sections themselves, so adding a row or editing its URL
    /// reloads while renaming one doesn't.
    /// Includes the promoted section: choosing a hero changes neither the
    /// catalog nor the section list, so without it the load never re-runs and
    /// the feed is never told which section to build the hero from.
    var customSectionsKey: String {
        "\(customSectionsCacheKey)-hero-\(heroSectionRaw)"
    }

    private var customSectionsCacheKey: String {
        "custom-\(trendingKey)-\(CustomHomeSections.contentSignature(visibleCustomSections))"
    }

    /// Creates Home's starting hero the first time it is needed, as an ordinary
    /// section. Runs once: deleting it leaves it deleted.
    private func seedDefaultHeroIfNeeded() {
        switch CustomHomeSections.seedingDefaultHero(
            surface: .home,
            sections: customSections,
            heroRaw: heroSectionRaw,
            orderRaw: sectionOrderRaw,
            seeded: heroSeeded
        ) {
        case let .seed(sections, heroToken, orderRaw):
            customSectionsRaw = CustomHomeSections.encode(sections)
            sectionOrderRaw = orderRaw
            heroSectionRaw = heroToken
            heroSeeded = true
        case .alreadyHasHero:
            heroSeeded = true
        case .nothingToDo:
            break
        }
    }

    var customSections: [CustomHomeSection] {
        CustomHomeSections.decode(customSectionsRaw)
    }

    /// The custom sections that should actually be fetched: the user's list
    /// minus the ones they've hidden. A hidden row costs no network.
    private var visibleCustomSections: [CustomHomeSection] {
        customSections.filter {
            // The promoted section is still fetched — it feeds the hero even
            // though it draws no row.
            .custom($0.id) == heroRef
                || HomeLayoutSettings.isEnabled(.custom($0.id), disabledRaw: disabledSectionsRaw)
        }
    }

    /// What the feed needs to match remote titles against the local catalog.
    private var feedContext: SectionFeed.Context {
        SectionFeed.Context(
            modelContext: modelContext,
            restriction: restriction,
            playlistPrefix: playlistPrefix
        )
    }

    /// Identity of the series resume lookup. Resuming or finishing an episode
    /// stamps its series' `lastWatchedDate` (`WatchProgressWriter`), which is
    /// exactly what the Recently Watched query orders by — so the newest stamp
    /// moves whenever a resume bar would.
    private var seriesResumeKey: String {
        let newest = watchedSeries.first?.lastWatchedDate?.timeIntervalSince1970 ?? 0
        return "resume-\(watchedSeries.count)-\(newest)-\(selectedPlaylistID)"
    }

    // MARK: - Playlist scoping

    /// The id prefix every Movie/Series/LiveStream belonging to the active
    /// playlist shares (ids are stored as `"\(playlistID)-…"`). The `@Query`
    /// results span all playlists, so this scopes them in-memory.
    var playlistPrefix: String? {
        activePlaylist.map { "\($0.id.uuidString)-" }
    }

    func belongsToActivePlaylist(_ id: String) -> Bool {
        guard let prefix = playlistPrefix else { return true }
        return id.hasPrefix(prefix)
    }

    // MARK: - Derived content

    /// The channels Home may show: none when this profile has Live TV switched
    /// off. That area leaves the navigation and stops syncing, so its channels
    /// shouldn't keep turning up inside Home's mixed rows either — and unlike
    /// movies and series, they have no row of their own to switch off, because
    /// they only ever appear alongside other media.
    private func visibleChannels(_ streams: [LiveStream]) -> [LiveStream] {
        guard AppAreaSettings.isEnabled(.liveTV, disabledRaw: disabledAreasRaw) else { return [] }
        return streams.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction)
    }

    private var recentlyWatched: [HomeMediaItem] {
        let items = watchedMovies.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.movie)
            + watchedSeries.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.series)
            + visibleChannels(watchedStreams).map(HomeMediaItem.live)
        return items
            .sorted { ($0.lastWatchedDate ?? .distantPast) > ($1.lastWatchedDate ?? .distantPast) }
            // After sorting, so the copy kept is the one watched most recently.
            .deduplicatedByTitle()
            .prefix(10)
            .map(\.self)
    }

    private var favorites: [HomeMediaItem] {
        let movies = favoriteMovies.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction)
        let series = favoriteSeries.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction)
        let streams = visibleChannels(favoriteStreams)

        // Interleave the three types by the cross-type `favoriteOrder` set in
        // Content Management → Favorites, so a movie placed above a channel shows
        // above it here too. Items never reordered (nil) fall back to a stable
        // type/name grouping (channels, movies, then series) — the same fallback
        // the favorites manager uses.
        let entries: [(order: Int?, rank: Int, name: String, item: HomeMediaItem)] =
            streams.map { ($0.favoriteOrder, 0, $0.name, HomeMediaItem.live($0)) }
                + movies.map { ($0.favoriteOrder, 1, $0.name, HomeMediaItem.movie($0)) }
                + series.map { ($0.favoriteOrder, 2, $0.name, HomeMediaItem.series($0)) }

        return entries
            .sorted { ($0.order ?? Int.max, $0.rank, $0.name) < ($1.order ?? Int.max, $1.rank, $1.name) }
            .map(\.item)
            .deduplicatedByTitle()
    }

    /// Truly empty home — only show the empty state once trending has settled
    /// so async-loaded content doesn't make the empty view flash on launch.
    private var isEmpty: Bool {
        recentlyWatched.isEmpty
            && favorites.isEmpty
            && feed.items(for: .builtin(.trendingMovies)).isEmpty
            && feed.items(for: .builtin(.trendingSeries)).isEmpty
            && feed.items(for: .builtin(.traktWatchlist)).isEmpty
            && visibleCustomSections.allSatisfy { feed.items(for: .custom($0.id)).isEmpty }
            && !sportsRailHasContent
            && feed.isSettled
    }

    // MARK: - Recently watched

    /// Clears an item's watch timestamp so it drops out of the Recently Watched
    /// row. The @Query-backed rows update automatically once the change is saved.
    private func removeFromRecentlyWatched(_ item: HomeMediaItem) {
        switch item {
        case let .movie(movie): movie.lastWatchedDate = nil
        case let .series(series): series.lastWatchedDate = nil
        case let .live(stream): stream.lastWatchedDate = nil
        }
        try? modelContext.save()
    }

    // MARK: - Series resume

    /// Resolves the resume bar for every partially-watched series in one indexed
    /// fetch, off the main thread. The rails then read a plain dictionary rather
    /// than each card faulting its series' whole `episodes` relationship from
    /// `body` — the same hoist the Live TV list does for now/next EPG.
    private func loadSeriesResume() async {
        let container = modelContext.container
        seriesResume = await Task.detached(priority: .userInitiated) {
            SeriesResumeLoader.load(container: container)
        }.value
    }
}

private extension HomeView {
    /// A standard Home rail that only renders when it has items. The Recently
    /// Watched rail passes `onRemove` to add its remove-from-history action.
    @ViewBuilder
    func rail(
        _ title: Text,
        _ items: [HomeMediaItem],
        section: HomeSectionRef? = nil,
        title collectionTitle: String? = nil,
        onRemove: ((HomeMediaItem) -> Void)? = nil
    ) -> some View {
        if !items.isEmpty {
            HomeRow(
                title: title,
                items: items,
                seriesResume: seriesResume,
                onPlayLive: playChannel,
                showAll: collectionSelection(for: section, title: collectionTitle),
                onRemove: onRemove,
                onStartMultiView: startMultiView,
                animationNamespace: animationNamespace
            )
        }
    }

    func collectionSelection(
        for section: HomeSectionRef?,
        title: String?
    ) -> SectionCollectionSelection? {
        guard let section, let title,
              feed.collection(for: section)?.hasMoreCandidates == true else { return nil }
        return SectionCollectionSelection(section: section, title: title)
    }
}

#Preview("Empty") {
    HomeView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    HomeView()
        .modelContainer(previewContainer())
}

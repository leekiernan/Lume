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
    /// Not `private`: read by the HomeView+DerivedContent extension (separate file).
    @Query var watchedStreams: [LiveStream]

    // Favorites.
    @Query var favoriteMovies: [Movie]
    @Query var favoriteSeries: [Series]
    /// Not `private`: read by the HomeView+DerivedContent extension (separate file).
    @Query var favoriteStreams: [LiveStream]

    /// The remote-backed rows (trending, Trakt watchlist, custom lists) — see
    /// `SectionFeed`. Not `private`:
    /// read by the HomeView+DerivedContent extension (separate file).
    @State var feed = SectionFeed(surface: .home)
    /// Resume fractions for partially-watched series, keyed by series id and
    /// resolved off the main thread — see `SeriesResumeLoader`. Not `private`:
    /// written by the HomeView+DerivedContent extension (separate file).
    @State var seriesResume: [String: Double] = [:]
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

    init() {
        // Recently watched: non-nil lastWatchedDate, newest first.
        var movies = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.lastWatchedDate != nil },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        movies.fetchLimit = 20
        _watchedMovies = Query(movies)

        var series = FetchDescriptor<Series>(
            predicate: #Predicate { $0.lastWatchedDate != nil },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        series.fetchLimit = 20
        _watchedSeries = Query(series)

        // Channels hidden in Content Management drop out here, the same way Live
        // TV drops them; a hidden *category* is handled by `excludingRestricted`.
        var streams = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.lastWatchedDate != nil && $0.isHidden == false },
            sortBy: [SortDescriptor(\.lastWatchedDate, order: .reverse)]
        )
        streams.fetchLimit = 20
        _watchedStreams = Query(streams)

        // Favorites: by the unified favorites order (Content Management →
        // Favorites), falling back to name; capped. The cross-type interleave
        // happens in the `favorites` accessor.
        var favMovies = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        favMovies.fetchLimit = 30
        _favoriteMovies = Query(favMovies)

        var favSeries = FetchDescriptor<Series>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        favSeries.fetchLimit = 30
        _favoriteSeries = Query(favSeries)

        var favStreams = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.isFavorite && $0.isHidden == false },
            sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name)]
        )
        favStreams.fetchLimit = 30
        _favoriteStreams = Query(favStreams)
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
                            // showing; without one, Home takes the standard
                            // section inset.
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
        ForEach(HomeLayoutSettings.resolve(orderRaw: sectionOrderRaw, custom: customSections, surface: .home)) { ref in
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
            // verbatim; the items are resolved by `SectionFeed`.
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
    /// opt-in (which also gates its recompute); the rest follow the user's
    /// per-section switches.
    func isSectionEnabled(_ section: HomeSection) -> Bool {
        section == .forYou
            ? (recommendationsEnabled && premium.isPremium)
            : HomeLayoutSettings.isEnabled(.builtin(section), disabledRaw: disabledSectionsRaw)
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
    /// reloads while renaming one doesn't — and, when a row reads from Trakt,
    /// the connected account, since that decides which private lists open.
    /// Includes the promoted section: choosing a hero changes neither the
    /// catalog nor the section list, so without it the load never re-runs and
    /// the feed is never told which section to build the hero from.
    var customSectionsKey: String {
        "\(customSectionsCacheKey)-hero-\(heroSectionRaw)"
    }

    private var customSectionsCacheKey: String {
        "custom-\(trendingKey)-\(CustomHomeSections.contentSignature(visibleCustomSections))"
            + CustomHomeSections.accountSignature(visibleCustomSections, traktUsername: trakt.username)
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
    /// minus the ones they've hidden. A hidden row costs no network. Not
    /// `private`: read by the HomeView+DerivedContent extension (separate file).
    var visibleCustomSections: [CustomHomeSection] {
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

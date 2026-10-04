import SwiftData
import SwiftUI

struct LibraryAreaView<Kind: LibraryAreaKind>: View {
    var resumeLoader: SeriesResumeLoadMachine?
    var watchedSeries: [Series]
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    // Optional so previews (which don't inject it) fall back to a local path.
    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?
    @State private var fallbackPath = NavigationPath()
    @Query private var playlists: [Playlist]
    /// The active playlist's visible categories, scoped in SQL — see `init`.
    @Query private var categories: [Category]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var showingSync = false
    @State private var showingSettings = false
    @State private var showingBrowse = false
    /// The remote-backed rows and the hero above them, shared with Home — see
    /// `SectionFeed`. Owned here rather than by `LibrarySectionsView` because on
    /// tvOS the hero sits outside the rows, wrapping them.
    @State private var feed: SectionFeed
    @State private var genreLoader = LibraryGenreLoadMachine()

    @AppStorage private var heroSectionRaw: String
    @AppStorage private var disabledSectionsRaw: String
    @AppStorage private var customSectionsRaw: String
    @State private var heroWarmStart: HeroWarmStartState

    /// The playlist scope and the viewer's hidden/restricted categories are
    /// passed in by `MainTabView`, as for `HomeView`: a `@Query` can't read view
    /// state, but it can be built from init arguments, so the category list is
    /// selected in SQL instead of fetching every playlist's categories and
    /// filtering them on every body pass.
    init(playlistPrefix: String? = nil, restriction: ContentRestriction = ContentRestriction(), resumeLoader: SeriesResumeLoadMachine? = nil, watchedSeries: [Series] = []) {
        self.resumeLoader = resumeLoader
        self.watchedSeries = watchedSeries
        _feed = State(initialValue: SectionFeed(surface: Kind.surface))
        _heroWarmStart = State(initialValue: HeroWarmStartState(surface: Kind.surface))
        _heroSectionRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.heroSectionKey(Kind.surface))
        _disabledSectionsRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.disabledSectionsKey(Kind.surface))
        _customSectionsRaw = AppStorage(wrappedValue: "", CustomHomeSections.storageKey(Kind.surface))
        _categories = Query(LibraryCategoryQuery.descriptor(
            type: Kind.categoryType,
            playlistPrefix: playlistPrefix ?? "",
            excludedCategoryIDs: restriction.excludedCategoryIDs
        ))
    }

    var body: some View {
        // Sorted once per pass: the empty check, the sidebar toggle and the
        // sidebar itself all read it.
        let sortedCategories = CategorySortOption.playlist.sort(categories)
        NavigationStack(path: navigationPath) {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: Kind.playlistEmptyIcon,
                        description: Text(Kind.playlistEmptyDescription)
                    )
                } else if sortedCategories.isEmpty {
                    ContentUnavailableView(
                        Kind.emptyTitle,
                        systemImage: Kind.emptyIcon,
                        description: Text(Kind.libraryEmptyDescription)
                    )
                } else {
                    sections
                }
            }
            .profileMenuToolbar()
            .libraryToolbar(config: LibraryToolbarConfiguration(
                playlists: playlists,
                selectedPlaylistID: $selectedPlaylistID,
                showingSync: $showingSync,
                showingSettings: $showingSettings,
                activePlaylist: activePlaylist
            ))
            .browseSidebarToolbar(isPresented: $showingBrowse, isEnabled: !sortedCategories.isEmpty)
            .navigationDestination(for: Category.self) { category in
                CatalogCategoryView<Kind>(category: category, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: LibraryCollection.self) { collection in
                Kind.collectionPage(collection.kind, prefix: playlistPrefix, namespace: animationNamespace)
            }
            .navigationDestination(for: SectionCollectionSelection.self) { selection in
                SectionCollectionView(
                    selection: selection,
                    feed: feed,
                    animationNamespace: animationNamespace
                )
            }
            .navigationDestination(for: GenreSelection.self) { selection in
                CatalogGenreView<Kind>(genre: selection.genre, playlistPrefix: playlistPrefix, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: Kind.Item.self) { item in
                Kind.detail(item, namespace: animationNamespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: item.id, in: animationNamespace))
                #endif
            }
        }
        // Above the stack, so the panel covers the navigation bar too — the
        // bar draws over anything inside the stack.
        .overlay(alignment: .leading) {
            LibraryBrowseSidebar(
                isPresented: $showingBrowse,
                categories: sortedCategories,
                genres: genreLoader.snapshot(for: genreKey),
                type: Kind.categoryType,
                onSelectCategory: { open($0) },
                onSelectGenre: { open(genre: $0) }
            )
        }
    }

    private var sections: some View {
        heroAndRows
            .browseActivity()
            .onChange(of: feed.heroItems.first, initial: true) { _, hero in
                rememberHeroWarmStart(hero?.imageURL)
            }
            .task(id: genreKey) {
                await genreLoader.load(for: genreKey) {
                    await Kind.genres(in: modelContext.container, prefix: playlistPrefix, restriction: restriction)
                }
            }
            .task(id: resumeKey) {
                if let resumeLoader, let resumeKey {
                    await resumeLoader.load(for: resumeKey, in: modelContext.container)
                }
            }
    }

    private var genreKey: LibraryGenreLoadKey {
        .init(prefix: playlistPrefix, visibility: restriction.visibilityToken, profile: ActiveProfileStore.current, syncedAt: activePlaylist?.lastSyncDate)
    }

    private var resumeKey: SeriesResumeLoadKey? {
        guard resumeLoader != nil else { return nil }
        return SeriesResumeLoadKey(playlistPrefix: playlistPrefix.isEmpty ? nil : playlistPrefix,
                                   restriction: restriction, watched: watchedSeries)
    }

    /// The same slideshow Home shows, filtered to this page's medium, above the
    /// page's rows. tvOS keeps the immersive treatment (`TVHomeScreen` wraps the
    /// rows in the fold); everywhere else it is the standard carousel.
    private var heroAndRows: some View {
        HeroFeedPage(
            heroItems: feed.heroItems, reservesHero: feed.heroState.reservesSpace,
            warmStartBackdropURL: heroWarmStartBackdropURL,
            warmStartPosterURL: { heroWarmStart.posterURL(hero: heroRef, catalogScope: heroWarmStartScope) },
            onSelectHero: open(hero:), rows: { rowsContent }
        )
    }

    @ViewBuilder
    private var rowsContent: some View {
        LibrarySectionsView(
            surface: Kind.surface,
            catalogKey: catalogKey,
            feed: feed,
            feedContext: SectionFeed.Context(
                modelContext: modelContext,
                restriction: restriction,
                playlistPrefix: playlistPrefix.isEmpty ? nil : playlistPrefix
            ),
            seriesResume: resumeKey.flatMap { resumeLoader?.snapshot(for: $0).fractions } ?? [:],
            animationNamespace: animationNamespace,
            onRevealBrowse: { showingBrowse = true },
            collectionRow: { kind in
                Kind.collectionRow(kind, prefix: playlistPrefix, excluded: restriction.excludedCategoryIDs,
                                   namespace: animationNamespace, onLeadingLeft: { showingBrowse = true })
            }
        )

        BrowseCategoriesButton(isPresented: $showingBrowse)
    }

    // MARK: - Navigation

    /// Drives the stack from the shared `DeepLinkRouter` so an `onOpenURL` push
    /// lands here; falls back to a local path in previews where no router exists.
    private var navigationPath: Binding<NavigationPath> {
        guard let router else { return $fallbackPath }
        return Kind.pathBinding(in: router)
    }

    /// Selecting the hero opens that title.
    private func open(hero: HeroItem) {
        if let item = Kind.heroItem(hero) {
            navigationPath.wrappedValue.append(item)
        }
    }

    /// Picking from the sidebar navigates rather than filtering the page behind
    /// it, so the panel closes as the push lands.
    private func open(_ category: Category) {
        showingBrowse = false
        navigationPath.wrappedValue.append(category)
    }

    private func open(genre: String) {
        showingBrowse = false
        navigationPath.wrappedValue.append(GenreSelection(genre: genre, type: Kind.categoryType))
    }

    // MARK: - Playlist scoping

    /// The playlist whose content is currently shown, resolved from the global
    /// selection. Falls back to the first playlist until the user picks one.
    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// The id prefix every Movie/Category of the active playlist shares. Scopes
    /// the collection rows' queries, the genre list and the "Show All" grids.
    /// `MainTabView` derives the same prefix for this view's category query.
    private var playlistPrefix: String {
        activePlaylist?.contentIDPrefix ?? ""
    }

    /// Identity of the catalog the remote rows are matched against — the same
    /// inputs Home's trending key uses.
    private var catalogKey: String {
        let synced = activePlaylist?.lastSyncDate?.timeIntervalSince1970 ?? 0
        return "\(Kind.surface.rawValue)-\(playlists.count)-\(selectedPlaylistID)-\(synced)-\(restriction.visibilityToken)"
    }

    private var heroRef: HomeSectionRef? {
        guard let ref = HomeLayoutSettings.heroRef(heroSectionRaw),
              HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
        else { return nil }
        return ref
    }

    private var heroWarmStartScope: String {
        HeroWarmStartCache.catalogScope(
            playlistID: activePlaylist?.id,
            visibilityToken: restriction.visibilityToken,
            hero: heroRef,
            customSections: CustomHomeSections.decode(customSectionsRaw)
        )
    }

    private var heroWarmStartBackdropURL: URL? {
        heroWarmStart.backdropURL(hero: heroRef, catalogScope: heroWarmStartScope)
    }

    private func rememberHeroWarmStart(_ backdropURL: URL?) {
        heroWarmStart.remember(backdropURL, hero: heroRef, catalogScope: heroWarmStartScope, posterURL: feed.heroItems.first?.posterURL)
    }
}

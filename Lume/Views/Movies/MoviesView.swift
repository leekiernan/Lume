//
//  MoviesView.swift
//  Lume
//
//  The Movies page. Like Home, it is built out of configurable rows (Settings ›
//  Layout › Movies — see `LibrarySectionsView`), scoped so every row only ever
//  shows movies. The provider's own categories moved into the browse sidebar,
//  which is hidden until asked for.
//

import SwiftData
import SwiftUI

struct MoviesView: View {
    @Namespace private var animationNamespace
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    // Optional so previews (which don't inject it) fall back to a local path.
    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?
    @State private var fallbackPath = NavigationPath()
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "vod" && $0.isHidden == false })
    private var categories: [Category]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var showingSync = false
    @State private var showingSettings = false
    @State private var showingBrowse = false
    /// The remote-backed rows and the hero above them, shared with Home — see
    /// `SectionFeed`. Owned here rather than by `LibrarySectionsView` because on
    /// tvOS the hero sits outside the rows, wrapping them.
    @State private var feed = SectionFeed(surface: .movies)
    @State private var genres: [String] = []

    @AppStorage(HomeLayoutSettings.heroSectionKey(.movies)) private var heroSectionRaw = ""
    @AppStorage(HomeLayoutSettings.disabledSectionsKey(.movies)) private var disabledSectionsRaw = ""
    @State private var heroWarmStart = HeroWarmStartState(surface: .movies)

    @AppStorage(SortStorageKey.movieCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    var body: some View {
        NavigationStack(path: navigationPath) {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "film.stack",
                        description: Text("Add a playlist in Settings to start browsing movies")
                    )
                } else if sortedCategories.isEmpty {
                    ContentUnavailableView(
                        "No Movies",
                        systemImage: "film.stack",
                        description: Text("Sync your playlist to load movies")
                    )
                } else {
                    sections
                }
            }
            .platformNavigationTitle("Movies")
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
            .browseSidebarToolbar(isPresented: $showingBrowse, isEnabled: !sortedCategories.isEmpty)
            .overlay(alignment: .leading) {
                LibraryBrowseSidebar(
                    isPresented: $showingBrowse,
                    categories: sortedCategories,
                    genres: genres,
                    type: .vod,
                    onSelectCategory: { open($0) },
                    onSelectGenre: { open(genre: $0) }
                )
            }
            .navigationDestination(for: Category.self) { category in
                MovieCategoryView(category: category, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: LibraryCollection.self) { collection in
                MovieCollectionView(kind: collection.kind, playlistPrefix: playlistPrefix, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: SectionCollectionSelection.self) { selection in
                SectionCollectionView(
                    selection: selection,
                    feed: feed,
                    animationNamespace: animationNamespace
                )
            }
            .navigationDestination(for: GenreSelection.self) { selection in
                MovieGenreView(genre: selection.genre, playlistPrefix: playlistPrefix, animationNamespace: animationNamespace)
            }
            .navigationDestination(for: Movie.self) { movie in
                MovieDetailView(movie: movie, animationNamespace: animationNamespace)
                #if os(iOS)
                    .navigationTransition(.zoom(sourceID: movie.id, in: animationNamespace))
                #endif
            }
        }
    }

    private var sections: some View {
        heroAndRows
            .browseActivity()
            .onChange(of: feed.heroItems.first?.imageURL, initial: true) { _, backdropURL in
                rememberHeroWarmStart(backdropURL)
            }
            .task(id: playlistPrefix) {
                genres = await GenreDerivation.movieGenres(in: modelContext.container, playlistPrefix: playlistPrefix, restriction: restriction)
            }
    }

    /// The same slideshow Home shows, filtered to this page's medium, above the
    /// page's rows. tvOS keeps the immersive treatment (`TVHomeScreen` wraps the
    /// rows in the fold); everywhere else it is the standard carousel.
    @ViewBuilder
    private var heroAndRows: some View {
        #if os(tvOS)
            TVHomeScreen(
                heroItems: feed.heroItems,
                reservesHero: heroRef != nil,
                warmStartBackdropURL: heroWarmStartBackdropURL,
                onSelectHero: open(hero:)
            ) {
                rowsContent
            }
        #else
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PosterCardMetrics.sectionSpacing) {
                    if !feed.heroItems.isEmpty {
                        HomeHeroCarousel(items: feed.heroItems)
                    } else if heroRef != nil {
                        HomeHeroWarmStart(backdropURL: heroWarmStartBackdropURL)
                    }
                    rowsContent
                }
                // The hero fills the top inset itself when it's showing.
                .padding(.top, heroRef == nil ? PosterCardMetrics.sectionVerticalPadding : 0)
                .padding(.bottom, PosterCardMetrics.sectionVerticalPadding)
            }
            .ignoresSafeArea(edges: heroRef == nil ? [] : .top)
        #endif
    }

    @ViewBuilder
    private var rowsContent: some View {
        LibrarySectionsView(
            surface: .movies,
            catalogKey: catalogKey,
            feed: feed,
            feedContext: SectionFeed.Context(
                modelContext: modelContext,
                restriction: restriction,
                playlistPrefix: playlistPrefix.isEmpty ? nil : playlistPrefix
            ),
            animationNamespace: animationNamespace,
            onRevealBrowse: { showingBrowse = true },
            collectionRow: { kind in
                MovieCollectionRow(
                    kind: kind,
                    playlistPrefix: playlistPrefix,
                    animationNamespace: animationNamespace,
                    onLeadingLeft: { showingBrowse = true }
                )
            }
        )

        BrowseCategoriesButton(isPresented: $showingBrowse)
    }

    // MARK: - Navigation

    /// Drives the stack from the shared `DeepLinkRouter` so an `onOpenURL` push
    /// lands here; falls back to a local path in previews where no router exists.
    private var navigationPath: Binding<NavigationPath> {
        guard let router else { return $fallbackPath }
        return Binding(get: { router.moviesPath }, set: { router.moviesPath = $0 })
    }

    /// Selecting the hero opens that title.
    private func open(hero: HeroItem) {
        if let item = hero.movie {
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
        navigationPath.wrappedValue.append(GenreSelection(genre: genre, type: .vod))
    }

    // MARK: - Playlist scoping

    /// The playlist whose content is currently shown, resolved from the global
    /// selection. Falls back to the first playlist until the user picks one.
    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// The id prefix every Movie/Category of the active playlist shares. Used to
    /// scope the cross-category collection rows in-memory.
    private var playlistPrefix: String {
        activePlaylist.map { "\($0.id.uuidString)-" } ?? ""
    }

    /// Identity of the catalog the remote rows are matched against — the same
    /// inputs Home's trending key uses.
    private var catalogKey: String {
        let synced = activePlaylist?.lastSyncDate?.timeIntervalSince1970 ?? 0
        return "movies-\(playlists.count)-\(selectedPlaylistID)-\(synced)-\(restriction.visibilityToken)"
    }

    private var heroRef: HomeSectionRef? {
        guard let ref = HomeLayoutSettings.heroRef(heroSectionRaw),
              HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
        else { return nil }
        return ref
    }

    private var heroWarmStartScope: String {
        activePlaylist?.id.uuidString ?? "none"
    }

    private var heroWarmStartBackdropURL: URL? {
        heroWarmStart.backdropURL(hero: heroRef, catalogScope: heroWarmStartScope)
    }

    private func rememberHeroWarmStart(_ backdropURL: URL?) {
        heroWarmStart.remember(backdropURL, hero: heroRef, catalogScope: heroWarmStartScope)
    }

    /// Categories scoped to the active playlist. The `@Query` fetches every
    /// playlist's categories (SwiftData can't parameterize a `@Query` on view
    /// state), so we isolate by the playlist-prefixed category `id` here.
    private var sortedCategories: [Category] {
        guard let playlistId = activePlaylist?.id else { return [] }
        let prefix = "\(playlistId.uuidString)-"
        return categorySort.sort(categories.filter { $0.id.hasPrefix(prefix) && !restriction.hides(categoryID: $0.id) })
    }
}

#Preview("Empty") {
    MoviesView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    MoviesView()
        .modelContainer(previewContainer())
}

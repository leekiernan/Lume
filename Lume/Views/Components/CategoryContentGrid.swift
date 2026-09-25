//
//  CategoryContentGrid.swift
//  Lume
//
//  Shared grid and preview-row components used by both Movies and Series
//  category views, minimising duplication between the two.
//

import SwiftData
import SwiftUI

// MARK: - Full Category Content Grid ("Show All")

struct CategoryContentGrid<Item: Identifiable & Hashable & WatchlistFavoritable, Card: View>: View {
    let title: String
    let items: [Item]
    let animationNamespace: Namespace.ID?
    let emptyTitle: LocalizedStringKey
    let emptyIcon: String
    let emptyDescription: LocalizedStringKey
    @Binding var sortRaw: String
    /// Whether to surface the content sort menu. Categories are user-sortable;
    /// the Favorites / Recently Watched collections have an intrinsic order
    /// (alphabetical / most-recent-first) and pass `false` to hide it.
    var showsSortMenu: Bool = true
    /// Called when the last item appears, so a paginating caller can fetch the
    /// next page. Nil callers load their full set up front (unchanged behavior).
    var onLoadMore: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @ViewBuilder let card: (Item) -> Card

    private let columns = [GridItem(.adaptive(minimum: PosterCardMetrics.gridMinimum), spacing: PosterCardMetrics.gridSpacing)]

    var body: some View {
        ScrollView {
            // tvOS suppresses the system navigation title (it renders centred and
            // the tab bar only shows the section, not the category), so we surface
            // the category name as a leading-aligned heading in the content itself.
            #if os(tvOS)
                Text(title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 40)
            #endif

            if items.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyIcon,
                    description: Text(emptyDescription)
                )
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: PosterCardMetrics.gridSpacing) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            card(item)
                                .matchedTransitionSourceIfAvailable(id: item.id, in: animationNamespace)
                        }
                        .posterCardButtonStyle()
                        .onAppear {
                            if let onLoadMore, item.id == items.last?.id { onLoadMore() }
                        }
                        .mediaFavoriteMenu(
                            isFavorite: { item.isFavorite },
                            onToggleFavorite: { MediaFavorites.toggle(item, in: modelContext) }
                        )
                    }
                }
                .padding()
            }
        }
        .browseActivity()
        // tvOS surfaces sorting through the tab bar's library controls instead of a
        // toolbar, mirroring the main browse views.
        #if !os(tvOS)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    ContentSortMenu(sortRaw: $sortRaw)
                }
            }
        #endif
    }
}

// MARK: - Movie Category View

struct MovieCategoryView: View {
    let category: Category
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext

    @AppStorage(SortStorageKey.movieContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue

    @State private var movies: [Movie] = []
    @State private var canLoadMore = true
    @State private var isLoadingPage = false
    /// True while a Stalker category's content is being fetched from the portal
    /// on first open — drives the loading overlay.
    @State private var isImporting = false
    /// The sort the current pages were loaded for. Pushing a detail cancels and
    /// (on pop) re-runs `.task`; reloading page one there would discard the
    /// loaded pages and reset the scroll position. Reload only when this differs.
    @State private var loadedSort: String?

    /// A category in a large IPTV playlist can hold thousands of titles; fetch a
    /// page at a time and load the next as the grid nears the end, rather than
    /// hydrating the whole category into memory at once.
    private let pageSize = 100

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    /// The playlist when it's a Stalker portal, whose categories are imported
    /// on demand rather than synced whole.
    private var stalkerPlaylist: Playlist? {
        guard let playlist = category.playlist, playlist.sourceType == .stalker else { return nil }
        return playlist
    }

    var body: some View {
        grid
            .overlay {
                if isImporting, movies.isEmpty {
                    ProgressView("Loading…")
                }
            }
            .task(id: contentSortRaw) {
                guard loadedSort != contentSortRaw else { return }
                loadedSort = contentSortRaw
                movies = []
                canLoadMore = true
                await importStalkerContentIfNeeded()
                loadNextPage()
                await revalidateStalkerContentIfStale()
            }
    }

    @ViewBuilder
    private var grid: some View {
        let base = CategoryContentGrid(
            title: category.name,
            items: movies,
            animationNamespace: animationNamespace,
            emptyTitle: "No Movies",
            emptyIcon: "film.stack",
            emptyDescription: "This category has no movies",
            sortRaw: $contentSortRaw,
            onLoadMore: { loadNextPage() },
            card: { MovieCardView(movie: $0, fillsWidth: true) }
        )
        // Pull-to-refresh re-imports a Stalker category from the portal without
        // waiting out `Category.stalkerContentTTL`. Not offered for fully-synced
        // sources.
        #if !os(tvOS)
            if stalkerPlaylist != nil {
                base.refreshable { await reimportStalkerContent() }
            } else {
                base
            }
        #else
            base
        #endif
    }

    private func loadNextPage() {
        guard canLoadMore, !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        let categoryId = category.id
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.categoryId == categoryId },
            sortBy: contentSort.movieDescriptors
        )
        descriptor.fetchOffset = movies.count
        descriptor.fetchLimit = pageSize
        let page = (try? modelContext.fetch(descriptor)) ?? []
        movies.append(contentsOf: page)
        if page.count < pageSize { canLoadMore = false }
    }

    /// Imports the category from the portal the first time it's opened (Stalker
    /// only; other sources are already fully synced).
    private func importStalkerContentIfNeeded() async {
        guard let playlist = stalkerPlaylist, category.contentImportedAt == nil else { return }
        await runStalkerImport(playlist: playlist)
    }

    /// Re-imports a previously imported category once its content outlives
    /// `Category.stalkerContentTTL`, then swaps the refreshed rows in beneath
    /// the grid. Runs after the local pages are already showing, so the user
    /// browses the cached snapshot while the portal walk happens — the only
    /// refresh path on tvOS, which has no pull-to-refresh.
    private func revalidateStalkerContentIfStale() async {
        guard let playlist = stalkerPlaylist,
              category.contentImportedAt != nil, category.stalkerContentStale else { return }
        await runStalkerImport(playlist: playlist)
        reloadLoadedPages()
    }

    private func reimportStalkerContent() async {
        guard let playlist = stalkerPlaylist else { return }
        await runStalkerImport(playlist: playlist)
        movies = []
        canLoadMore = true
        loadNextPage()
    }

    /// Re-fetches the already-loaded window in place. Row identity is stable
    /// (persistent model ids), so unchanged items keep the scroll position;
    /// only added/removed titles shift.
    private func reloadLoadedPages() {
        let categoryId = category.id
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.categoryId == categoryId },
            sortBy: contentSort.movieDescriptors
        )
        let window = max(movies.count, pageSize)
        descriptor.fetchLimit = window
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        canLoadMore = rows.count == window
        movies = rows
    }

    private func runStalkerImport(playlist: Playlist) async {
        isImporting = true
        defer { isImporting = false }
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        _ = try? await manager.importStalkerCategory(apiId: category.apiId, type: .vod, playlist: playlist)
    }
}

// MARK: - Previews

#Preview("Movie Category Grid") {
    let container = previewContainer()
    let categories = (try? container.mainContext.fetch(FetchDescriptor<Category>())) ?? []
    let category = categories.first { $0.typeRaw == "vod" } ?? categories[0]
    return NavigationStack {
        MovieCategoryView(category: category, animationNamespace: nil)
    }
    .modelContainer(container)
}

#Preview("Movie Category Empty") {
    let container = previewContainer()
    let emptyCategory = Category(apiId: "999", name: "Empty Category", parentId: 0, type: .vod, playlist: PreviewData.samplePlaylist)
    return NavigationStack {
        MovieCategoryView(category: emptyCategory, animationNamespace: nil)
    }
    .modelContainer(container)
}

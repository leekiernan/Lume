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
    var isLoading = false
    /// Called when the last item appears, so a paginating caller can fetch the
    /// next page. Nil callers load their full set up front (unchanged behavior).
    var onLoadMore: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @ViewBuilder let card: (Item) -> Card

    private let columns = [GridItem(.adaptive(minimum: PosterCardMetrics.gridMinimum), spacing: PosterCardMetrics.gridSpacing)]

    var body: some View {
        CategoryPage(title: title) {
            switch CollectionGridPresentation.resolve(hasItems: !items.isEmpty, isLoading: isLoading) {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            case .empty:
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyIcon,
                    description: Text(emptyDescription)
                )
                .padding(.top, 40)
            case .content:
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
    }
}

// MARK: - Category page

/// The frame every category-style page shares — a Movies or Series category,
/// a Sports team or league: one scrolling page, titled by the navigation bar,
/// or on tvOS (which suppresses that title) by a leading heading in the
/// content. Callers supply what sits under it.
struct CategoryPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

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

            content()
        }
        .browseActivity()
        #if !os(tvOS)
            .navigationTitle(title)
            .macNavigationBack()
        #endif
    }
}

// MARK: - Movie Category View

struct MovieCategoryView: View {
    let category: Category
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext

    @State private var movies: [Movie] = []
    @State private var pagination = PaginationMachine()
    /// True while a Stalker category's content is being fetched from the portal
    /// on first open — drives the grid's loading state.
    @State private var isImporting = false
    /// A category in a large IPTV playlist can hold thousands of titles; fetch a
    /// page at a time and load the next as the grid nears the end, rather than
    /// hydrating the whole category into memory at once.
    private let pageSize = 100

    /// The playlist when it's a Stalker portal, whose categories are imported
    /// on demand rather than synced whole.
    private var stalkerPlaylist: Playlist? {
        guard let playlist = category.playlist, playlist.sourceType == .stalker else { return nil }
        return playlist
    }

    var body: some View {
        grid
            .task(id: category.id) {
                guard pagination.prepare(for: category.id) else { return }
                movies = []
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
            isLoading: pagination.key != category.id || pagination.isLoading || isImporting,
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
        guard let request = pagination.beginLoading() else { return }
        let categoryId = category.id
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.categoryId == categoryId },
            sortBy: ContentSortOption.playlist.movieDescriptors
        )
        descriptor.fetchOffset = request.offset
        descriptor.fetchLimit = pageSize
        let page: [Movie]
        do {
            page = try modelContext.fetch(descriptor)
        } catch {
            pagination.abandon(request)
            return
        }
        guard pagination.finish(request, scanned: page.count, hasMore: page.count == pageSize) else { return }
        movies.append(contentsOf: page)
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
        guard pagination.restart() else { return }
        movies = []
        loadNextPage()
    }

    /// Re-fetches the already-loaded window in place. Row identity is stable
    /// (persistent model ids), so unchanged items keep the scroll position;
    /// only added/removed titles shift.
    private func reloadLoadedPages() {
        let categoryId = category.id
        var descriptor = FetchDescriptor<Movie>(
            predicate: #Predicate { $0.categoryId == categoryId },
            sortBy: ContentSortOption.playlist.movieDescriptors
        )
        let window = max(movies.count, pageSize)
        descriptor.fetchLimit = window
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        pagination.replaceWindow(scanned: rows.count, hasMore: rows.count == window)
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

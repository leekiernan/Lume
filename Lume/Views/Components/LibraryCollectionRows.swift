//
//  LibraryCollectionRows.swift
//  Lume
//
//  The "Recently Watched" and "Favorites" rows shown above the category rows on
//  the Movies and Series tabs, plus their "Show All" grids. These collections
//  cut across categories — a favorite or recently-watched title can live in any
//  category — so they're driven by their own predicates rather than a
//  `categoryId`, mirroring the Home screen's rows.
//
//  Each surface scopes its @Query to the active playlist inside the predicate:
//  ids are playlist-prefixed, so `id.starts(with:)` is a prefix match SQLite
//  answers itself. Scoping in memory instead meant every row hydrated every
//  playlist's matches and then threw most of them away, on every catalog write
//  — 0.85 ms for a fresh library, 59 ms once 3,035 movies carried a watch date.
//  The viewer's hidden-category state is part of every query too — preview rows
//  and full-grid pages alike — so hidden rows cannot consume a limit before being
//  discarded, the same way Home's rows are built (`HomeQuery`). Rows render
//  nothing when empty so a fresh library degrades gracefully.
//

import SwiftData
import SwiftUI

// MARK: - Navigation value

/// A cross-category library collection reachable via "Show All". Carried as a
/// navigation value so Movies and Series can each register a destination for it.
struct LibraryCollection: Hashable {
    enum Kind: String, Hashable {
        case recentlyWatched
        case favorites
        case recentlyAdded

        var title: LocalizedStringKey {
            switch self {
            case .recentlyWatched: "Recently Watched"
            case .favorites: "Favorites"
            case .recentlyAdded: "Recently Added"
            }
        }

        var emptyIcon: String {
            switch self {
            case .recentlyWatched: "clock.arrow.circlepath"
            case .favorites: "heart"
            case .recentlyAdded: "sparkles"
            }
        }
    }

    let kind: Kind
    let type: CategoryType
}

/// How many items each preview row shows before "Show All".
let collectionPreviewLimit = 20

/// Upper bound on a preview row's fetch: the preview plus one, which is all a
/// row needs to know whether "Show All" has anything more to show. Tight because
/// the hidden-category filter runs in the query, before the limit. Unbounded,
/// Recently Watched and Favorites re-fetched every matching row in the store on
/// every catalog write.
let collectionRowFetchLimit = collectionPreviewLimit + 1

// MARK: - Shared preview row

/// A titled horizontal rail with a trailing "Show All" link into the full
/// collection grid, keyed by a `LibraryCollection` destination.
private struct CollectionPreviewRow<Item: Identifiable & Hashable & WatchlistFavoritable, Card: View>: View {
    let title: LocalizedStringKey
    let collection: LibraryCollection
    let items: [Item]
    /// Whether the full collection holds more items than this preview shows.
    /// When false, the "Show All" link is hidden — there's nothing more to see.
    let hasMore: Bool
    let animationNamespace: Namespace.ID?
    /// When set, each card gains a destructive "Remove from Recently Watched"
    /// context menu (a long-press on the focused card on tvOS). Nil for rows
    /// where removal doesn't apply, e.g. Favorites.
    var removeAction: ((Item) -> Void)?
    /// tvOS: pressing left on the row's first card — see `onLeadingEdgeLeft`.
    var onLeadingLeft: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(PosterCardMetrics.railTitleFont)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)

                Spacer()

                if hasMore {
                    NavigationLink(value: collection) {
                        Text("Show All")
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PosterCardMetrics.railSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: item) {
                            card(item)
                                .matchedTransitionSourceIfAvailable(id: item.id, in: animationNamespace)
                        }
                        .posterCardButtonStyle()
                        .onLeadingEdgeLeft(index == 0 ? onLeadingLeft : nil)
                        .mediaFavoriteMenu(
                            isFavorite: { item.isFavorite },
                            onToggleFavorite: { MediaFavorites.toggle(item, in: modelContext) },
                            onRemoveFromRecents: removeAction.map { action in { action(item) } }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, PosterCardMetrics.railVerticalPadding)
            }
            .scrollClipDisabled()
            .frame(height: PosterCardMetrics.rowHeight)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}

// MARK: - Movies

/// A Movies-tab collection preview row (Recently Watched or Favorites). Renders
/// nothing when the active playlist has no matching movies.
struct MovieCollectionRow: View {
    let kind: LibraryCollection.Kind
    var animationNamespace: Namespace.ID?
    /// tvOS: pressing left on the row's first card — see `onLeadingEdgeLeft`.
    var onLeadingLeft: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Query private var movies: [Movie]

    /// `excludedCategoryIDs` is the viewer's `ContentRestriction`, passed in
    /// rather than read from the environment because the `@Query` is built
    /// here, before the environment exists.
    init(
        kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>,
        animationNamespace: Namespace.ID? = nil,
        onLeadingLeft: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.animationNamespace = animationNamespace
        self.onLeadingLeft = onLeadingLeft
        _movies = Query(MovieCollectionQuery.rowDescriptor(
            for: kind,
            playlistPrefix: playlistPrefix,
            excludedCategoryIDs: excludedCategoryIDs
        ))
    }

    var body: some View {
        let items = Array(movies.deduplicatedByTitle().prefix(collectionPreviewLimit))
        if !items.isEmpty {
            CollectionPreviewRow(
                title: kind.title,
                collection: LibraryCollection(kind: kind, type: .vod),
                items: items,
                // Against the raw fetch: a title collapsed as a duplicate still
                // means the full grid holds more than this row.
                hasMore: movies.count > items.count,
                animationNamespace: animationNamespace,
                removeAction: kind == .recentlyWatched ? { movie in
                    movie.lastWatchedDate = nil
                    try? modelContext.save()
                } : nil,
                onLeadingLeft: onLeadingLeft,
                card: { MovieCardView(movie: $0) }
            )
        }
    }
}

/// The full grid behind a Movies collection's "Show All".
struct MovieCollectionView: View {
    let kind: LibraryCollection.Kind
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @State private var collection = PagedCollection<Movie>()

    private let pageSize = 100

    init(kind: LibraryCollection.Kind, playlistPrefix: String, animationNamespace: Namespace.ID? = nil) {
        self.kind = kind
        self.playlistPrefix = playlistPrefix
        self.animationNamespace = animationNamespace
    }

    var body: some View {
        let emptyDescription: LocalizedStringKey = switch kind {
        case .favorites: "Movies you mark as favorites will appear here"
        case .recentlyWatched: "Movies you watch will appear here"
        case .recentlyAdded: "Movies recently added to your library will appear here"
        }
        CategoryContentGrid(
            title: kind.localizedTitleString,
            items: collection.items,
            animationNamespace: animationNamespace,
            emptyTitle: kind.title,
            emptyIcon: kind.emptyIcon,
            emptyDescription: emptyDescription,
            sortRaw: .constant(""),
            showsSortMenu: false,
            onLoadMore: loadNextPage,
            card: { MovieCardView(movie: $0, fillsWidth: true) }
        )
        .task(id: requestKey) {
            collection.prepare(for: requestKey)
            loadNextPage()
        }
    }

    private var requestKey: String {
        "\(kind.rawValue)-\(playlistPrefix)-\(restriction.visibilityToken)"
    }

    private func loadNextPage() {
        collection.loadNextPage(
            in: modelContext,
            pageSize: pageSize,
            deduplicateBy: { $0.tmdbId.map(AnyHashable.init) },
            descriptor: { offset, limit in
                MovieCollectionQuery.pageDescriptor(
                    for: kind,
                    playlistPrefix: playlistPrefix,
                    excludedCategoryIDs: restriction.excludedCategoryIDs,
                    offset: offset,
                    limit: limit
                )
            }
        )
    }
}

/// Internal, not fileprivate, so the tests and benchmarks can build these
/// descriptors and assert their shape — the `fetchLimit`, the playlist scope and
/// the lexical `added` comparator are performance contracts a well-meaning
/// refactor can undo without changing a single visible row. Same reasoning as
/// the search predicates in `SearchFetching.swift`.
enum MovieCollectionQuery {
    /// The fetch behind a preview row — always bounded, see
    /// `collectionRowFetchLimit`.
    static func rowDescriptor(
        for kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<Movie> {
        var descriptor = base(for: kind, playlistPrefix: playlistPrefix, excludedCategoryIDs: excludedCategoryIDs)
        descriptor.fetchLimit = collectionRowFetchLimit
        return descriptor
    }

    /// Unbounded descriptor retained for benchmarks and callers that explicitly
    /// need a complete result. The shipping full grid uses `pageDescriptor`.
    static func gridDescriptor(for kind: LibraryCollection.Kind, playlistPrefix: String) -> FetchDescriptor<Movie> {
        base(for: kind, playlistPrefix: playlistPrefix)
    }

    static func pageDescriptor(
        for kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>,
        offset: Int,
        limit: Int
    ) -> FetchDescriptor<Movie> {
        var descriptor = base(
            for: kind,
            playlistPrefix: playlistPrefix,
            excludedCategoryIDs: excludedCategoryIDs
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    private static func base(
        for kind: LibraryCollection.Kind,
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String> = []
    ) -> FetchDescriptor<Movie> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        return switch kind {
        case .recentlyWatched:
            FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.lastWatchedDate != nil
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [
                    SortDescriptor(\.lastWatchedDate, order: .reverse),
                    SortDescriptor(\.name),
                    SortDescriptor(\.id)
                ]
            )
        case .favorites:
            FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.isFavorite
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                // The user's arrangement from Content Management › Favorites,
                // as on Home. Never-reordered favorites (nil) sort by name.
                sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name), SortDescriptor(\.id)]
            )
        case .recentlyAdded:
            // `comparator: .lexical`, not the `.localizedStandard` default:
            // `added` is a Unix timestamp string, and the localized comparator
            // emits `COLLATE NSCollateFinderlike`, which the `#Index` on
            // `Movie.added` cannot serve. 222.4 ms → 92.6 ms on a 179k-title
            // catalog, and that one query was 46% of a cold launch's SQL.
            FetchDescriptor<Movie>(
                predicate: #Predicate {
                    $0.added != nil
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [
                    SortDescriptor(\.added, comparator: .lexical, order: .reverse),
                    SortDescriptor(\.num),
                    SortDescriptor(\.id)
                ]
            )
        }
    }
}

// MARK: - Series

/// A Series-tab collection preview row (Recently Watched or Favorites). Renders
/// nothing when the active playlist has no matching series.
struct SeriesCollectionRow: View {
    let kind: LibraryCollection.Kind
    var animationNamespace: Namespace.ID?
    /// tvOS: pressing left on the row's first card — see `onLeadingEdgeLeft`.
    var onLeadingLeft: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Query private var series: [Series]

    /// `excludedCategoryIDs` is the viewer's `ContentRestriction`, passed in
    /// rather than read from the environment because the `@Query` is built
    /// here, before the environment exists.
    init(
        kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>,
        animationNamespace: Namespace.ID? = nil,
        onLeadingLeft: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.animationNamespace = animationNamespace
        self.onLeadingLeft = onLeadingLeft
        _series = Query(SeriesCollectionQuery.rowDescriptor(
            for: kind,
            playlistPrefix: playlistPrefix,
            excludedCategoryIDs: excludedCategoryIDs
        ))
    }

    var body: some View {
        let items = Array(series.deduplicatedByTitle().prefix(collectionPreviewLimit))
        if !items.isEmpty {
            CollectionPreviewRow(
                title: kind.title,
                collection: LibraryCollection(kind: kind, type: .series),
                items: items,
                // Against the raw fetch: a title collapsed as a duplicate still
                // means the full grid holds more than this row.
                hasMore: series.count > items.count,
                animationNamespace: animationNamespace,
                removeAction: kind == .recentlyWatched ? { series in
                    series.lastWatchedDate = nil
                    try? modelContext.save()
                } : nil,
                onLeadingLeft: onLeadingLeft,
                card: { SeriesCardView(series: $0) }
            )
        }
    }
}

/// The full grid behind a Series collection's "Show All".
struct SeriesCollectionView: View {
    let kind: LibraryCollection.Kind
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @State private var collection = PagedCollection<Series>()

    private let pageSize = 100

    init(kind: LibraryCollection.Kind, playlistPrefix: String, animationNamespace: Namespace.ID? = nil) {
        self.kind = kind
        self.playlistPrefix = playlistPrefix
        self.animationNamespace = animationNamespace
    }

    var body: some View {
        let emptyDescription: LocalizedStringKey = switch kind {
        case .favorites: "Series you mark as favorites will appear here"
        case .recentlyWatched: "Series you watch will appear here"
        case .recentlyAdded: "Series recently added to your library will appear here"
        }
        CategoryContentGrid(
            title: kind.localizedTitleString,
            items: collection.items,
            animationNamespace: animationNamespace,
            emptyTitle: kind.title,
            emptyIcon: kind.emptyIcon,
            emptyDescription: emptyDescription,
            sortRaw: .constant(""),
            showsSortMenu: false,
            onLoadMore: loadNextPage,
            card: { SeriesCardView(series: $0, fillsWidth: true) }
        )
        .task(id: requestKey) {
            collection.prepare(for: requestKey)
            loadNextPage()
        }
    }

    private var requestKey: String {
        "\(kind.rawValue)-\(playlistPrefix)-\(restriction.visibilityToken)"
    }

    private func loadNextPage() {
        collection.loadNextPage(
            in: modelContext,
            pageSize: pageSize,
            deduplicateBy: { $0.tmdbId.map(AnyHashable.init) },
            descriptor: { offset, limit in
                SeriesCollectionQuery.pageDescriptor(
                    for: kind,
                    playlistPrefix: playlistPrefix,
                    excludedCategoryIDs: restriction.excludedCategoryIDs,
                    offset: offset,
                    limit: limit
                )
            }
        )
    }
}

/// Internal for the same reason as `MovieCollectionQuery`.
enum SeriesCollectionQuery {
    /// The fetch behind a preview row — always bounded, see
    /// `collectionRowFetchLimit`.
    static func rowDescriptor(
        for kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>
    ) -> FetchDescriptor<Series> {
        var descriptor = base(for: kind, playlistPrefix: playlistPrefix, excludedCategoryIDs: excludedCategoryIDs)
        descriptor.fetchLimit = collectionRowFetchLimit
        return descriptor
    }

    /// Unbounded descriptor retained for benchmarks and explicit complete reads.
    static func gridDescriptor(for kind: LibraryCollection.Kind, playlistPrefix: String) -> FetchDescriptor<Series> {
        base(for: kind, playlistPrefix: playlistPrefix)
    }

    static func pageDescriptor(
        for kind: LibraryCollection.Kind,
        playlistPrefix: String,
        excludedCategoryIDs: Set<String>,
        offset: Int,
        limit: Int
    ) -> FetchDescriptor<Series> {
        var descriptor = base(
            for: kind,
            playlistPrefix: playlistPrefix,
            excludedCategoryIDs: excludedCategoryIDs
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return descriptor
    }

    private static func base(
        for kind: LibraryCollection.Kind,
        playlistPrefix prefix: String,
        excludedCategoryIDs: Set<String> = []
    ) -> FetchDescriptor<Series> {
        let excluded = Set(excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        return switch kind {
        case .recentlyWatched:
            FetchDescriptor<Series>(
                predicate: #Predicate {
                    $0.lastWatchedDate != nil
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [
                    SortDescriptor(\.lastWatchedDate, order: .reverse),
                    SortDescriptor(\.name),
                    SortDescriptor(\.id)
                ]
            )
        case .favorites:
            FetchDescriptor<Series>(
                predicate: #Predicate {
                    $0.isFavorite
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                // The user's arrangement from Content Management › Favorites,
                // as on Home. Never-reordered favorites (nil) sort by name.
                sortBy: [SortDescriptor(\.favoriteOrder), SortDescriptor(\.name), SortDescriptor(\.id)]
            )
        case .recentlyAdded:
            // `comparator: .lexical` for the same reason as the movie side:
            // `lastModified` is a Unix timestamp string, and the default
            // localized comparator forfeits the `#Index` to NSCollateFinderlike.
            FetchDescriptor<Series>(
                predicate: #Predicate {
                    $0.lastModified != nil
                        && $0.id.starts(with: prefix)
                        && (!filtersCategories || $0.categoryId == nil || !excluded.contains($0.categoryId))
                },
                sortBy: [
                    SortDescriptor(\.lastModified, comparator: .lexical, order: .reverse),
                    SortDescriptor(\.num),
                    SortDescriptor(\.id)
                ]
            )
        }
    }
}

// MARK: - Title bridging

private extension LibraryCollection.Kind {
    /// `CategoryContentGrid` takes a plain `String` title (it surfaces the
    /// category name, normally already a `String`). These collections have a
    /// fixed English name we localize at the call site for the grid heading.
    var localizedTitleString: String {
        switch self {
        case .recentlyWatched: String(localized: "Recently Watched")
        case .favorites: String(localized: "Favorites")
        case .recentlyAdded: String(localized: "Recently Added")
        }
    }
}

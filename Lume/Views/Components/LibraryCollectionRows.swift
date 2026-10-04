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
        /// In progress.
        case continueWatching
        /// Finished, to watch again.
        case recentlyWatched
        case favorites
        case recentlyAdded

        var title: LocalizedStringKey {
            switch self {
            case .continueWatching: "Continue Watching"
            case .recentlyWatched: "Watch Again"
            case .favorites: "Favorites"
            case .recentlyAdded: "Recently Added"
            }
        }

        var emptyIcon: String {
            switch self {
            case .continueWatching: "play.circle"
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
/// grid. `showAll` is the navigation value the link pushes: a
/// `LibraryCollection` here, a search section in `SearchView`.
struct CollectionPreviewRow<Item: Identifiable & Hashable & WatchlistFavoritable, Destination: Hashable, Card: View>: View {
    let title: LocalizedStringKey
    let showAll: Destination
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
        PosterRail(title: Text(title), showAll: hasMore ? showAll : nil, groupsFocus: true) {
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
        let collection = LibraryCollection(kind: kind, type: .vod)
        if kind == .continueWatching, !items.isEmpty {
            ContinueWatchingRow(
                items: items.map(HomeMediaItem.movie),
                series: ContinueWatchingLoader.Result(),
                onPlayLive: { _ in },
                showAll: movies.count > items.count ? collection : nil,
                onRemove: { item in
                    guard case let .movie(movie) = item else { return }
                    forget(movie)
                },
                onLeadingLeft: onLeadingLeft,
                animationNamespace: animationNamespace
            )
        } else if !items.isEmpty {
            CollectionPreviewRow(
                title: kind.title,
                showAll: collection,
                items: items,
                // Against the raw fetch: a title collapsed as a duplicate still
                // means the full grid holds more than this row.
                hasMore: movies.count > items.count,
                animationNamespace: animationNamespace,
                removeAction: kind == .recentlyWatched ? { forget($0) } : nil,
                onLeadingLeft: onLeadingLeft,
                card: { MovieCardView(movie: $0) }
            )
        }
    }

    /// Takes a movie out of both watch rails.
    private func forget(_ movie: Movie) {
        movie.lastWatchedDate = nil
        ContentClearLedger.shared.record(movie.id)
        try? modelContext.save()
    }
}

/// The full grid behind a Movies collection's "Show All".
typealias MovieCollectionView = CatalogCollectionView<MovieCatalog>

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
    /// Which watched series are finished — splits them between the two watch
    /// rails (`ContinueWatchingLoader`).
    @State private var progress = ContinueWatchingLoader.Result()

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
        let shown = SeriesWatchSplit.shown(series, for: kind, progress: progress)
        let items = Array(shown.deduplicatedByTitle().prefix(collectionPreviewLimit))
        let collection = LibraryCollection(kind: kind, type: .series)
        Group {
            if kind == .continueWatching, !items.isEmpty {
                ContinueWatchingRow(
                    items: items.map(HomeMediaItem.series),
                    series: progress,
                    onPlayLive: { _ in },
                    showAll: shown.count > items.count ? collection : nil,
                    onRemove: { item in
                        guard case let .series(show) = item else { return }
                        forget(show)
                    },
                    onLeadingLeft: onLeadingLeft,
                    animationNamespace: animationNamespace
                )
            } else if !items.isEmpty {
                CollectionPreviewRow(
                    title: kind.title,
                    showAll: collection,
                    items: items,
                    // Against the raw fetch: a title collapsed as a duplicate still
                    // means the full grid holds more than this row.
                    hasMore: shown.count > items.count,
                    animationNamespace: animationNamespace,
                    removeAction: kind == .recentlyWatched ? { forget($0) } : nil,
                    onLeadingLeft: onLeadingLeft,
                    card: { SeriesCardView(series: $0) }
                )
            }
        }
        .task(id: SeriesWatchSplit.key(series, for: kind)) {
            guard SeriesWatchSplit.splits(kind) else { return }
            progress = await ContinueWatchingLoader.load(series, in: modelContext)
        }
    }

    /// Takes a series out of both watch rails.
    private func forget(_ series: Series) {
        series.lastWatchedDate = nil
        ContentClearLedger.shared.record(series.id)
        try? modelContext.save()
    }
}

/// The two watch collections share one series query; this is where they part.
enum SeriesWatchSplit {
    static func splits(_ kind: LibraryCollection.Kind) -> Bool {
        kind == .continueWatching || kind == .recentlyWatched
    }

    /// Finished series for Recently Watched, the rest for Continue Watching —
    /// one whose episodes aren't loaded counts as in progress. Other kinds
    /// pass through.
    static func shown(_ series: [Series], for kind: LibraryCollection.Kind, progress: ContinueWatchingLoader.Result) -> [Series] {
        switch kind {
        case .continueWatching: series.filter { !progress.finished.contains($0.id) }
        case .recentlyWatched: series.filter { progress.finished.contains($0.id) }
        case .favorites, .recentlyAdded: series
        }
    }

    /// Reloads when the list changes or any of it is watched again.
    static func key(_ series: [Series], for kind: LibraryCollection.Kind) -> [String] {
        guard splits(kind) else { return [] }
        return series.map { "\($0.id)|\($0.lastWatchedDate?.timeIntervalSince1970 ?? 0)" }
    }

    /// The split for a grid's loaded pages, loading further pages while it
    /// would show nothing and the source has more. The pages come from the one
    /// watched-series query and are split afterwards, and a grid asks for
    /// another page only when its last card appears: a page wholly on the
    /// other side of the split — Watch Again behind unfinished shows, Continue
    /// Watching behind finished ones — would otherwise end the walk with an
    /// empty grid. Stops at the end of the source, when a page adds nothing (a
    /// failed fetch), and on cancellation, returning `nil` so the caller keeps
    /// the split it has.
    static func settle(
        _ kind: LibraryCollection.Kind,
        collection: PagedCollection<Series>,
        progress: ([Series]) async -> ContinueWatchingLoader.Result,
        loadNextPage: () -> Void
    ) async -> ContinueWatchingLoader.Result? {
        while true {
            let items = collection.items
            let stamp = key(items, for: kind)
            let result = await progress(items)
            guard !Task.isCancelled else { return nil }
            // A user-driven page append or watch edit during the lookup is not
            // covered by that result. Resolve the new window before publishing.
            guard key(collection.items, for: kind) == stamp else { continue }
            guard shown(collection.items, for: kind, progress: result).isEmpty, collection.canLoadMore else {
                return result
            }
            let loaded = collection.items.count
            loadNextPage()
            guard collection.items.count > loaded else { return result }
        }
    }
}

/// The full grid behind a Series collection's "Show All".
typealias SeriesCollectionView = CatalogCollectionView<SeriesCatalog>

// MARK: - Title bridging

extension LibraryCollection.Kind {
    /// `CategoryContentGrid` takes a plain `String` title (it surfaces the
    /// category name, normally already a `String`). These collections have a
    /// fixed English name we localize at the call site for the grid heading.
    var localizedTitleString: String {
        switch self {
        case .continueWatching: String(localized: "Continue Watching")
        case .recentlyWatched: String(localized: "Watch Again")
        case .favorites: String(localized: "Favorites")
        case .recentlyAdded: String(localized: "Recently Added")
        }
    }
}

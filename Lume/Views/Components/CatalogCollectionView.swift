import SwiftData
import SwiftUI

@MainActor
protocol CatalogCollectionKind: CatalogBrowseKind {
    static func collectionDescriptor(_ kind: LibraryCollection.Kind, prefix: String, excluded: Set<String>, offset: Int, limit: Int) -> FetchDescriptor<Item>
    static func deduplicationKey(_ item: Item) -> AnyHashable?
    static func collectionDescription(_ kind: LibraryCollection.Kind) -> LocalizedStringKey
    static func splits(_ kind: LibraryCollection.Kind) -> Bool
    static func progressKey(_ items: [Item], kind: LibraryCollection.Kind) -> [String]
    static func shown(_ items: [Item], kind: LibraryCollection.Kind, progress: ContinueWatchingLoader.Result) -> [Item]
    static func settle(_ kind: LibraryCollection.Kind, collection: PagedCollection<Item>, context: ModelContext, loadNextPage: () -> Void) async -> ContinueWatchingLoader.Result?
}

extension CatalogCollectionKind {
    /// Preparation itself must change the task key, even for an empty first
    /// page. Otherwise the split task can exit before the query is prepared
    /// and never run again to settle the empty/loading state.
    static func progressRequestKey(request: String, loaded: String?, items: [Item], kind: LibraryCollection.Kind) -> [String] {
        [request, loaded ?? ""] + progressKey(items, kind: kind)
    }
}

/// Shared grid lifecycle; the adapter keeps concrete predicates and Series'
/// episode-completion split. Neither Movie nor genre/category grids inherit it.
struct CatalogCollectionView<Kind: CatalogCollectionKind>: View {
    let kind: LibraryCollection.Kind
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @State private var collection = PagedCollection<Kind.Item>()
    @State private var progress = ContinueWatchingLoader.Result()
    @State private var settledProgressKey: [String]?
    private let pageSize = 100

    var body: some View {
        CategoryContentGrid(
            title: kind.localizedTitleString,
            items: collection.pagination.key == requestKey ? Kind.shown(collection.items, kind: kind, progress: progress) : [],
            animationNamespace: animationNamespace, emptyTitle: kind.title, emptyIcon: kind.emptyIcon,
            emptyDescription: Kind.collectionDescription(kind),
            isLoading: collection.pagination.key != requestKey || collection.isLoading
                || (Kind.splits(kind) && settledProgressKey != progressKey),
            onLoadMore: loadNextPage, card: { Kind.card($0, fillsWidth: true) }
        )
        .task(id: requestKey) {
            collection.prepare(for: requestKey)
            loadNextPage()
        }
        .task(id: progressKey) {
            guard Kind.splits(kind), collection.pagination.key == requestKey else { return }
            let owner = requestKey
            let settled = await Kind.settle(kind, collection: collection, context: modelContext, loadNextPage: loadNextPage)
            guard !Task.isCancelled, collection.pagination.key == owner, let settled else { return }
            progress = settled
            settledProgressKey = progressKey
        }
    }

    private var requestKey: String {
        "\(kind.rawValue)-\(playlistPrefix)-\(restriction.visibilityToken)"
    }

    private var progressKey: [String] {
        Kind.progressRequestKey(request: requestKey, loaded: collection.pagination.key, items: collection.items, kind: kind)
    }

    private func loadNextPage() {
        guard collection.pagination.key == requestKey else { return }
        collection.loadNextPage(in: modelContext, pageSize: pageSize, deduplicateBy: Kind.deduplicationKey) { offset, limit in
            Kind.collectionDescriptor(kind, prefix: playlistPrefix, excluded: restriction.excludedCategoryIDs, offset: offset, limit: limit)
        }
    }
}

extension MovieCatalog: CatalogCollectionKind {
    static func collectionDescriptor(_ kind: LibraryCollection.Kind, prefix: String, excluded: Set<String>, offset: Int, limit: Int) -> FetchDescriptor<Movie> {
        MovieCollectionQuery.pageDescriptor(for: kind, playlistPrefix: prefix, excludedCategoryIDs: excluded, offset: offset, limit: limit)
    }

    static func deduplicationKey(_ item: Movie) -> AnyHashable? {
        item.tmdbId.map(AnyHashable.init)
    }

    static func collectionDescription(_ kind: LibraryCollection.Kind) -> LocalizedStringKey {
        switch kind {
        case .favorites: "Movies you mark as favorites will appear here"
        case .continueWatching, .recentlyWatched: "Movies you watch will appear here"
        case .recentlyAdded: "Movies recently added to your library will appear here"
        }
    }

    static func splits(_: LibraryCollection.Kind) -> Bool {
        false
    }

    static func progressKey(_: [Movie], kind _: LibraryCollection.Kind) -> [String] {
        []
    }

    static func shown(_ items: [Movie], kind _: LibraryCollection.Kind, progress _: ContinueWatchingLoader.Result) -> [Movie] {
        items
    }

    static func settle(_: LibraryCollection.Kind, collection _: PagedCollection<Movie>, context _: ModelContext, loadNextPage _: () -> Void) async -> ContinueWatchingLoader.Result? {
        nil
    }
}

extension SeriesCatalog: CatalogCollectionKind {
    static func collectionDescriptor(_ kind: LibraryCollection.Kind, prefix: String, excluded: Set<String>, offset: Int, limit: Int) -> FetchDescriptor<Series> {
        SeriesCollectionQuery.pageDescriptor(for: kind, playlistPrefix: prefix, excludedCategoryIDs: excluded, offset: offset, limit: limit)
    }

    static func deduplicationKey(_ item: Series) -> AnyHashable? {
        item.tmdbId.map(AnyHashable.init)
    }

    static func collectionDescription(_ kind: LibraryCollection.Kind) -> LocalizedStringKey {
        switch kind {
        case .favorites: "Series you mark as favorites will appear here"
        case .continueWatching, .recentlyWatched: "Series you watch will appear here"
        case .recentlyAdded: "Series recently added to your library will appear here"
        }
    }

    static func splits(_ kind: LibraryCollection.Kind) -> Bool {
        SeriesWatchSplit.splits(kind)
    }

    static func progressKey(_ items: [Series], kind: LibraryCollection.Kind) -> [String] {
        SeriesWatchSplit.key(items, for: kind)
    }

    static func shown(_ items: [Series], kind: LibraryCollection.Kind, progress: ContinueWatchingLoader.Result) -> [Series] {
        SeriesWatchSplit.shown(items, for: kind, progress: progress)
    }

    static func settle(_ kind: LibraryCollection.Kind, collection: PagedCollection<Series>, context: ModelContext, loadNextPage: () -> Void) async -> ContinueWatchingLoader.Result? {
        await SeriesWatchSplit.settle(kind, collection: collection,
                                      progress: { await ContinueWatchingLoader.load($0, in: context) }, loadNextPage: loadNextPage)
    }
}

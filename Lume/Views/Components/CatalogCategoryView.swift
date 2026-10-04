import SwiftData
import SwiftUI

struct CatalogCategoryView<Kind: CatalogBrowseKind>: View {
    let category: Category
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @State private var loader = CatalogCategoryLoadMachine<Kind.Item>()

    private var key: CatalogCategoryKey {
        .init(categoryID: category.id, visibility: restriction.visibilityToken, profile: ActiveProfileStore.current)
    }

    private var isVisible: Bool {
        !restriction.excludedCategoryIDs.contains(category.id)
    }

    var body: some View {
        grid.task(id: key) {
            guard isVisible else {
                loader.invalidate()
                return
            }
            await loader.open(category: category, key: key, fetch: fetch, importContent: importContent)
        }
    }

    @ViewBuilder
    private var grid: some View {
        let base = CategoryContentGrid(
            title: category.name, items: isVisible && loader.key == key ? loader.items : [], animationNamespace: animationNamespace,
            emptyTitle: Kind.emptyTitle, emptyIcon: Kind.emptyIcon, emptyDescription: Kind.categoryEmptyDescription,
            isLoading: isVisible && (loader.key != key || loader.pagination.isLoading || loader.isImporting),
            onLoadMore: {
                if isVisible, loader.key == key { loader.loadNextPage(fetch: fetch) }
            }, card: { Kind.card($0, fillsWidth: true) }
        )
        #if !os(tvOS)
            if category.playlist?.sourceType == .stalker {
                base.refreshable {
                    guard isVisible, loader.key == key else { return }
                    await loader.refresh(category: category, fetch: fetch, importContent: importContent)
                }
            } else {
                base
            }
        #else
            base
        #endif
    }

    private func fetch(_ id: String, _ offset: Int, _ limit: Int) throws -> [Kind.Item] {
        try Kind.categoryPage(in: modelContext, id: id, offset: offset, limit: limit)
    }

    private func importContent(_ category: Category, _ playlist: Playlist) async throws {
        let manager = ContentSyncManager(modelContainer: modelContext.container)
        _ = try await manager.importStalkerCategory(apiId: category.apiId, type: Kind.categoryType, playlist: playlist)
    }
}

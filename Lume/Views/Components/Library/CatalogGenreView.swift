import SwiftData
import SwiftUI

struct CatalogGenreView<Kind: CatalogBrowseKind>: View {
    let genre: String
    let playlistPrefix: String
    var animationNamespace: Namespace.ID?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    /// Observed, so a profile switch restarts the load; `ActiveProfileStore`
    /// alone is a UserDefaults read SwiftUI can't see change.
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @State private var loader = CatalogGenreLoadMachine<Kind.Item>()

    private var key: CatalogGenreKey {
        .init(genre: genre, playlistPrefix: playlistPrefix, visibility: restriction.visibilityToken, profile: profiles?.activeProfileID ?? ActiveProfileStore.current)
    }

    var body: some View {
        CategoryContentGrid(
            title: genre, items: loader.key == key ? loader.items : [], animationNamespace: animationNamespace,
            emptyTitle: Kind.emptyTitle, emptyIcon: Kind.emptyIcon, emptyDescription: Kind.genreEmptyDescription,
            isLoading: loader.key != key || loader.pagination.isLoading,
            onLoadMore: {
                if loader.key == key { loader.requestNextPage(excluded: restriction.excludedCategoryIDs, fetch: fetch, hydrate: hydrate) }
            },
            card: { Kind.card($0, fillsWidth: true) }
        )
        .task(id: key) {
            await loader.open(key: key, excluded: restriction.excludedCategoryIDs, fetch: fetch, hydrate: hydrate)
        }
        .onDisappear { loader.cancel() }
    }

    private func fetch(_ request: GenrePageRequest) async -> GenrePage {
        let container = modelContext.container
        return await Task.detached(priority: .userInitiated) {
            Kind.genrePage(container: container, request: request)
        }.value
    }

    private func hydrate(_ id: PersistentIdentifier) -> Kind.Item? {
        modelContext.model(for: id) as? Kind.Item
    }
}

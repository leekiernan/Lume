import SwiftData

nonisolated extension LiveChannelQuery {
    /// Snapshot for imperative in-player pickers. The browse screen retains its
    /// reactive @Query probes; all three surfaces share section composition.
    @MainActor
    static func rail(
        in context: ModelContext, playlistPrefix: String, restriction: ContentRestriction
    ) -> [LiveTVSection] {
        guard !playlistPrefix.isEmpty else { return [] }
        let descriptor = LibraryCategoryQuery.descriptor(
            type: .live, playlistPrefix: playlistPrefix,
            excludedCategoryIDs: restriction.excludedCategoryIDs
        )
        let categories = CategorySortOption.playlist.sort(
            visibleCategories(
                (try? context.fetch(descriptor)) ?? [],
                playlistPrefix: playlistPrefix, restriction: restriction
            )
        )
        // Independent, unsorted LIMIT 1 probes: a failed category fetch must
        // not suppress virtual sections, nor materialize whole channel lists.
        let favorites = (try? context.fetch(favoritesProbe(playlistPrefix: playlistPrefix, restriction: restriction))) ?? []
        let recents = (try? context.fetch(recentlyWatchedProbe(playlistPrefix: playlistPrefix, restriction: restriction))) ?? []
        return LiveTVSection.resolve(
            playlistPrefix: playlistPrefix, categories: categories.map(LiveTVSection.category),
            hasFavorites: !favorites.isEmpty, hasRecentlyWatched: !recents.isEmpty
        )
    }
}

import SwiftData
import SwiftUI

/// Shared adaptive geometry only. Callers keep their ForEach identity, padding,
/// loading/empty treatment and pagination triggers; no fetching occurs here.
struct PosterGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: PosterCardMetrics.gridMinimum), spacing: PosterCardMetrics.gridSpacing)],
            spacing: PosterCardMetrics.gridSpacing,
            content: content
        )
    }
}

/// The identical typed navigation, transition and favorite menu used by the
/// category, search and remote-collection grids. It does not erase destination
/// types or add Home's extra voting/recents/live-playback actions.
struct CatalogPosterLink<Item: Identifiable & Hashable & WatchlistFavoritable, Card: View>: View {
    let item: Item
    var animationNamespace: Namespace.ID?
    var onRemoveFromRecents: (() -> Void)?
    @ViewBuilder let card: (Item) -> Card
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationLink(value: item) {
            card(item)
                .matchedTransitionSourceIfAvailable(id: item.id, in: animationNamespace)
        }
        .posterCardButtonStyle()
        .mediaFavoriteMenu(
            item, in: modelContext,
            onRemoveFromRecents: onRemoveFromRecents
        )
    }
}

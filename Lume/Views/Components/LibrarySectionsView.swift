//
//  LibrarySectionsView.swift
//  Lume
//
//  The configurable rows on the Movies and Series pages — the same engine that
//  drives Home (`SectionSurface`, `HomeLayoutSettings`, `SectionFeed`), scoped
//  to one medium. The provider's own categories are no longer the landing
//  screen here; they moved behind `LibraryBrowseSidebar`.
//
//  The locally-queried rows (Recently Watched, Favorites, Recently Added) are
//  supplied by the caller as `collectionRow`, because Movies and Series each
//  have their own @Query-backed row and card type. Everything remote —
//  trending, the Trakt watchlist and the user's custom list rows — comes from
//  the shared feed and renders through `HomeRow`.
//

import SwiftUI

struct LibrarySectionsView<CollectionRow: View>: View {
    let surface: SectionSurface
    /// Identity of the catalog the rows are matched against: changes when the
    /// playlist, its last sync or the viewer's hidden categories change.
    let catalogKey: String
    let feedContext: SectionFeed.Context
    /// Resume fractions keyed by series id, resolved once for the screen.
    var seriesResume: [String: Double] = [:]
    var animationNamespace: Namespace.ID?
    /// tvOS: pressing left on any rail's leading card reveals the browse
    /// sidebar. The caller's `collectionRow` passes the same closure to its own
    /// rows, so every row behaves alike.
    var onRevealBrowse: (() -> Void)?
    /// The caller's @Query-backed row for one of the local collections.
    @ViewBuilder let collectionRow: (LibraryCollection.Kind) -> CollectionRow

    @State private var feed: SectionFeed
    @State private var trakt = TraktService.shared
    @AppStorage private var sectionOrderRaw: String
    @AppStorage private var disabledSectionsRaw: String
    @AppStorage private var customSectionsRaw: String

    init(
        surface: SectionSurface,
        catalogKey: String,
        feedContext: SectionFeed.Context,
        seriesResume: [String: Double] = [:],
        animationNamespace: Namespace.ID? = nil,
        onRevealBrowse: (() -> Void)? = nil,
        @ViewBuilder collectionRow: @escaping (LibraryCollection.Kind) -> CollectionRow
    ) {
        self.surface = surface
        self.catalogKey = catalogKey
        self.feedContext = feedContext
        self.seriesResume = seriesResume
        self.animationNamespace = animationNamespace
        self.onRevealBrowse = onRevealBrowse
        self.collectionRow = collectionRow
        _feed = State(wrappedValue: SectionFeed(surface: surface))
        _sectionOrderRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.sectionOrderKey(surface))
        _disabledSectionsRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.disabledSectionsKey(surface))
        _customSectionsRaw = AppStorage(wrappedValue: "", CustomHomeSections.storageKey(surface))
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: PosterCardMetrics.sectionSpacing) {
            ForEach(HomeLayoutSettings.resolve(orderRaw: sectionOrderRaw, custom: customSections, surface: surface)) { ref in
                row(for: ref)
            }
        }
        .task(id: catalogKey) {
            feed.update(context: feedContext)
            await feed.loadTrending(cacheKey: catalogKey)
        }
        .task(id: watchlistKey) {
            feed.update(context: feedContext)
            await feed.loadWatchlist(cacheKey: watchlistKey)
        }
        .task(id: customSectionsKey) {
            feed.update(context: feedContext)
            await feed.loadCustomSections(cacheKey: customSectionsKey, sections: visibleCustomSections)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for ref: HomeSectionRef) -> some View {
        switch ref {
        case let .builtin(section):
            if HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw) {
                builtinRow(for: section)
            }
        case let .custom(id):
            // A custom row's header is the user's own text, so it goes through
            // verbatim.
            if let section = customSections.first(where: { $0.id == id }),
               HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
            {
                rail(Text(verbatim: section.title), feed.customItems[id] ?? [])
            }
        }
    }

    @ViewBuilder
    private func builtinRow(for section: HomeSection) -> some View {
        switch section {
        case .recentlyWatched:
            collectionRow(.recentlyWatched)
        case .favorites:
            collectionRow(.favorites)
        case .recentlyAdded:
            collectionRow(.recentlyAdded)
        case .trendingMovies:
            rail(Text("Trending Movies"), feed.trendingMovies)
        case .trendingSeries:
            rail(Text("Trending Series"), feed.trendingSeries)
        case .traktWatchlist:
            rail(Text("From Your Trakt Watchlist"), feed.watchlist)
        case .forYou:
            // Home only — `HomeSection.cases(for:)` never yields it here.
            EmptyView()
        }
    }

    /// A standard rail that only renders when it has items. These pages carry
    /// no live channels, so the row's live-playback hook is unused.
    @ViewBuilder
    private func rail(_ title: Text, _ items: [HomeMediaItem]) -> some View {
        if !items.isEmpty {
            HomeRow(
                title: title,
                items: items,
                seriesResume: seriesResume,
                onPlayLive: { _ in },
                onLeadingLeft: onRevealBrowse,
                animationNamespace: animationNamespace
            )
        }
    }

    // MARK: - Load keys

    private var watchlistKey: String {
        "watchlist-\(surface.rawValue)-\(trakt.isConnected)-\(catalogKey)"
    }

    private var customSectionsKey: String {
        "custom-\(catalogKey)-\(CustomHomeSections.contentSignature(visibleCustomSections))"
    }

    private var customSections: [CustomHomeSection] {
        CustomHomeSections.decode(customSectionsRaw)
    }

    /// The custom sections that should actually be fetched: the user's list
    /// minus the ones they've hidden. A hidden row costs no network.
    private var visibleCustomSections: [CustomHomeSection] {
        customSections.filter {
            HomeLayoutSettings.isEnabled(.custom($0.id), disabledRaw: disabledSectionsRaw)
        }
    }
}

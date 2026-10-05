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
//  the shared feed and renders through `HomeRow`. Loading and first-use hero
//  seeding belong to LibraryAreaView, outside this lazy presentation subtree.
//

import SwiftUI

struct LibrarySectionsView<CollectionRow: View>: View {
    let surface: SectionSurface
    /// Owned by the page rather than here: the hero above these rows renders
    /// from the same feed, and on tvOS it sits outside them entirely.
    let feed: SectionFeed
    /// Resume fractions keyed by series id, resolved once for the screen.
    var seriesResume: [String: Double] = [:]
    var animationNamespace: Namespace.ID?
    /// tvOS: pressing left on any rail's leading card reveals the browse
    /// sidebar. The caller's `collectionRow` passes the same closure to its own
    /// rows, so every row behaves alike.
    var onRevealBrowse: (() -> Void)?
    /// The caller's @Query-backed row for one of the local collections.
    @ViewBuilder let collectionRow: (LibraryCollection.Kind) -> CollectionRow

    @AppStorage private var sectionOrderRaw: String
    @AppStorage private var disabledSectionsRaw: String
    @AppStorage private var customSectionsRaw: String
    @AppStorage private var heroSectionRaw: String

    init(
        surface: SectionSurface,
        feed: SectionFeed,
        seriesResume: [String: Double] = [:],
        animationNamespace: Namespace.ID? = nil,
        onRevealBrowse: (() -> Void)? = nil,
        @ViewBuilder collectionRow: @escaping (LibraryCollection.Kind) -> CollectionRow
    ) {
        self.surface = surface
        self.feed = feed
        self.seriesResume = seriesResume
        self.animationNamespace = animationNamespace
        self.onRevealBrowse = onRevealBrowse
        self.collectionRow = collectionRow
        _sectionOrderRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.sectionOrderKey(surface))
        _disabledSectionsRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.disabledSectionsKey(surface))
        _customSectionsRaw = AppStorage(wrappedValue: "", CustomHomeSections.storageKey(surface))
        _heroSectionRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.heroSectionKey(surface))
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: PosterCardMetrics.sectionSpacing) {
            ForEach(HomeLayoutSettings.resolve(orderRaw: sectionOrderRaw, custom: customSections, surface: surface)) { ref in
                row(for: ref)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for ref: HomeSectionRef) -> some View {
        switch ref {
        case let .builtin(section):
            // A promoted row is the hero, so it never also draws as a row.
            if ref != heroRef, HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw) {
                builtinRow(for: section)
            }
        case let .custom(id):
            // A custom row's header is the user's own text, so it goes through
            // verbatim.
            if ref != heroRef,
               let section = customSections.first(where: { $0.id == id }),
               HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
            {
                rail(Text(verbatim: section.title), feed.items(for: ref), section: ref, collectionTitle: section.title)
            }
        }
    }

    @ViewBuilder
    private func builtinRow(for section: HomeSection) -> some View {
        switch section {
        case .continueWatching:
            collectionRow(.continueWatching)
        case .recentlyWatched:
            collectionRow(.recentlyWatched)
        case .favorites:
            collectionRow(.favorites)
        case .recentlyAdded:
            collectionRow(.recentlyAdded)
        case .trendingMovies:
            rail(
                Text("Trending Movies"), feed.items(for: .builtin(section)),
                section: .builtin(section), collectionTitle: String(localized: "Trending Movies")
            )
        case .trendingSeries:
            rail(
                Text("Trending Series"), feed.items(for: .builtin(section)),
                section: .builtin(section), collectionTitle: String(localized: "Trending Series")
            )
        case .traktWatchlist, .simklWatchlist:
            if let provider = WatchlistProvider(section: section) {
                rail(
                    Text(provider.rowTitle), feed.items(for: .builtin(section)),
                    section: .builtin(section), collectionTitle: provider.rowTitleString
                )
            }
        case .forYou, .sports:
            // Home only — `HomeSection.cases(for:)` never yields either here.
            EmptyView()
        }
    }

    /// A standard rail that only renders when it has items. These pages carry
    /// no live channels, so the row's live-playback hook is unused.
    @ViewBuilder
    private func rail(
        _ title: Text,
        _ items: [HomeMediaItem],
        section: HomeSectionRef,
        collectionTitle: String
    ) -> some View {
        if !items.isEmpty {
            HomeRow(
                title: title,
                items: items,
                seriesResume: seriesResume,
                onPlayLive: { _ in },
                showAll: feed.collection(for: section)?.hasMoreCandidates == true
                    ? SectionCollectionSelection(section: section, title: collectionTitle)
                    : nil,
                onLeadingLeft: onRevealBrowse,
                animationNamespace: animationNamespace
            )
        }
    }

    /// The promoted row, if this surface has one and it is still switched on.
    private var heroRef: HomeSectionRef? {
        guard let ref = HomeLayoutSettings.heroRef(heroSectionRaw),
              HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
        else { return nil }
        return ref
    }

    private var customSections: [CustomHomeSection] {
        CustomHomeSections.decode(customSectionsRaw)
    }
}

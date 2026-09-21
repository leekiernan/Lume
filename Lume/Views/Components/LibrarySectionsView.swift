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
    /// Owned by the page rather than here: the hero above these rows renders
    /// from the same feed, and on tvOS it sits outside them entirely.
    let feed: SectionFeed
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

    @State private var trakt = TraktService.shared
    @AppStorage private var sectionOrderRaw: String
    @AppStorage private var disabledSectionsRaw: String
    @AppStorage private var customSectionsRaw: String
    @AppStorage private var heroSectionRaw: String
    @AppStorage private var heroSeeded: Bool

    init(
        surface: SectionSurface,
        catalogKey: String,
        feed: SectionFeed,
        feedContext: SectionFeed.Context,
        seriesResume: [String: Double] = [:],
        animationNamespace: Namespace.ID? = nil,
        onRevealBrowse: (() -> Void)? = nil,
        @ViewBuilder collectionRow: @escaping (LibraryCollection.Kind) -> CollectionRow
    ) {
        self.surface = surface
        self.catalogKey = catalogKey
        self.feed = feed
        self.feedContext = feedContext
        self.seriesResume = seriesResume
        self.animationNamespace = animationNamespace
        self.onRevealBrowse = onRevealBrowse
        self.collectionRow = collectionRow
        _sectionOrderRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.sectionOrderKey(surface))
        _disabledSectionsRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.disabledSectionsKey(surface))
        _customSectionsRaw = AppStorage(wrappedValue: "", CustomHomeSections.storageKey(surface))
        _heroSectionRaw = AppStorage(wrappedValue: "", HomeLayoutSettings.heroSectionKey(surface))
        _heroSeeded = AppStorage(wrappedValue: false, HomeLayoutSettings.heroSeededKey(surface))
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: PosterCardMetrics.sectionSpacing) {
            ForEach(HomeLayoutSettings.resolve(orderRaw: sectionOrderRaw, custom: customSections, surface: surface)) { ref in
                row(for: ref)
            }
        }
        .task(id: catalogKey) {
            feed.heroRef = heroRef
            feed.update(context: feedContext)
            await feed.loadTrending(cacheKey: catalogKey)
        }
        .task(id: watchlistKey) {
            feed.heroRef = heroRef
            feed.update(context: feedContext)
            await feed.loadWatchlist(cacheKey: watchlistKey)
        }
        .task(id: customSectionsKey) {
            seedDefaultHeroIfNeeded()
            feed.heroRef = heroRef
            feed.update(context: feedContext)
            await feed.loadCustomSections(cacheKey: customSectionsCacheKey, sections: visibleCustomSections)
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
        case .traktWatchlist:
            rail(
                Text("From Your Trakt Watchlist"), feed.items(for: .builtin(section)),
                section: .builtin(section), collectionTitle: String(localized: "From Your Trakt Watchlist")
            )
        case .forYou:
            // Home only — `HomeSection.cases(for:)` never yields it here.
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

    // MARK: - Load keys

    private var watchlistKey: String {
        "watchlist-\(surface.rawValue)-\(trakt.username ?? "disconnected")-\(catalogKey)"
    }

    /// Includes the promoted section: choosing a hero changes neither the
    /// catalog nor the section list, so without it the load never re-runs and
    /// the feed is never told which section to build the hero from.
    private var customSectionsKey: String {
        "\(customSectionsCacheKey)-hero-\(heroSectionRaw)"
    }

    private var customSectionsCacheKey: String {
        "custom-\(catalogKey)-\(CustomHomeSections.contentSignature(visibleCustomSections))"
    }

    /// The promoted row, if this surface has one and it is still switched on.
    private var heroRef: HomeSectionRef? {
        guard let ref = HomeLayoutSettings.heroRef(heroSectionRaw),
              HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
        else { return nil }
        return ref
    }

    /// Creates this surface's starting hero the first time it is needed, as an
    /// ordinary section. Runs once: deleting it leaves it deleted.
    private func seedDefaultHeroIfNeeded() {
        switch CustomHomeSections.seedingDefaultHero(
            surface: surface,
            sections: customSections,
            heroRaw: heroSectionRaw,
            orderRaw: sectionOrderRaw,
            seeded: heroSeeded
        ) {
        case let .seed(sections, heroToken, orderRaw):
            customSectionsRaw = CustomHomeSections.encode(sections)
            sectionOrderRaw = orderRaw
            heroSectionRaw = heroToken
            heroSeeded = true
        case .alreadyHasHero:
            heroSeeded = true
        case .nothingToDo:
            break
        }
    }

    private var customSections: [CustomHomeSection] {
        CustomHomeSections.decode(customSectionsRaw)
    }

    /// The custom sections that should actually be fetched: the user's list
    /// minus the ones they've hidden. A hidden row costs no network.
    private var visibleCustomSections: [CustomHomeSection] {
        customSections.filter {
            // The promoted section is still fetched — it feeds the hero even
            // though it draws no row.
            .custom($0.id) == heroRef
                || HomeLayoutSettings.isEnabled(.custom($0.id), disabledRaw: disabledSectionsRaw)
        }
    }
}

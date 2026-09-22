//
//  SectionFeed.swift
//  Lume
//
//  The remote-backed rows shared by every section surface (Home, Movies,
//  Series): TMDB trending, the Trakt watchlist, and the user's custom list
//  rows. Each surface owns one `SectionFeed`; the locally-queried rows
//  (Recently Watched, Favorites, Recently Added) stay as @Query-backed views.
//
//  Everything here matches remote titles against the local catalog by TMDB id
//  in batched queries, so a row only ever shows titles the active playlist
//  actually carries. `surface.mediaType` narrows that to one medium on the
//  Movies and Series pages — a movie list added there simply resolves to
//  nothing on the Series page rather than showing the wrong medium.
//

import OSLog
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SectionFeed {
    private enum CacheRestore {
        case missing
        case stale
        case fresh
    }

    /// What a load needs from the view: the store to match against, the
    /// viewer's hidden categories, and the active playlist's id prefix (nil
    /// means "no playlist scoping", which is what previews get).
    struct Context {
        let modelContext: ModelContext
        let restriction: ContentRestriction
        let playlistPrefix: String?

        func belongsToActivePlaylist(_ id: String) -> Bool {
            guard let playlistPrefix else { return true }
            return id.hasPrefix(playlistPrefix)
        }
    }

    let surface: SectionSurface

    /// Which row the surface shows as its hero, set from its stored preference
    /// before each load. Nothing stands in for it while that row loads, so the
    /// hero opens on its own content or on nothing, never on someone else's.
    var heroRef: HomeSectionRef?
    /// Bumped when hero artwork lands — see `refreshHeroArtwork`.
    var heroArtworkRevision = 0
    /// Fresh TMDB paths used immediately while the view context still holds the
    /// pre-enrichment version of a model. The same details are persisted by the
    /// enrichment actor for subsequent launches.
    var heroPresentationOverrides: [String: HeroPresentation] = [:]
    /// Prevents the independent trending, watchlist and custom-section loaders
    /// from requesting the same hero enrichment while another loader is still
    /// waiting for it.
    var heroEnrichmentIDs: Set<String> = []
    /// Every remote-backed row shares one representation: its lightweight
    /// ordered source plus a bounded catalog preview. The source tail remains
    /// available for an incrementally-loaded full grid without keeping all of
    /// its SwiftData models alive on the browse screen.
    private(set) var collections: [HomeSectionRef: SectionCollectionSnapshot] = [:]
    private(set) var trendingState: HomeLoadState = .idle
    private(set) var watchlistState: HomeLoadState = .idle
    private(set) var customState: HomeLoadState = .idle
    /// Sources that reached a terminal transport/provider failure without a
    /// usable cached collection. Kept per section so one failed custom list
    /// cannot make a successfully empty sibling look broken.
    private var failedSections: Set<HomeSectionRef> = []
    let loadGate = SectionFeedLoadGate()
    var context: Context?

    /// How many matched titles a remote-backed row shows.
    static let itemLimit = 20
    /// How many hero candidates the Home carousel pages through.
    static let heroLimit = 8

    init(surface: SectionSurface) {
        self.surface = surface
    }

    func items(for section: HomeSectionRef) -> [HomeMediaItem] {
        collections[section]?.preview ?? []
    }

    func collection(for section: HomeSectionRef) -> SectionCollectionSnapshot? {
        collections[section]
    }

    /// Resolves another local-catalog window from the retained source list.
    /// Nothing calls this from the 20-card rail; it is the common continuation
    /// path a full collection grid can use without refetching its remote list.
    func page(
        for section: HomeSectionRef,
        from cursor: Int,
        limit: Int = 100
    ) async -> SectionCollectionPage {
        guard let collection = collections[section], let context else {
            return SectionCollectionPage(items: [], nextOffset: cursor, hasMoreCandidates: false)
        }
        return await page(entries: collection.entries, from: cursor, limit: limit, context: context)
    }

    /// Resolves a page from a grid's captured source snapshot. A feed may
    /// revalidate while the grid is open; keeping that grid on one ordered
    /// source prevents its cursor from suddenly referring to a different list.
    func page(
        entries: [HomeListEntry],
        from cursor: Int,
        limit: Int = 100
    ) async -> SectionCollectionPage {
        guard let context else {
            return SectionCollectionPage(items: [], nextOffset: cursor, hasMoreCandidates: false)
        }
        return await page(entries: entries, from: cursor, limit: limit, context: context)
    }

    private func page(
        entries: [HomeListEntry],
        from cursor: Int,
        limit: Int,
        context: Context
    ) async -> SectionCollectionPage {
        await SectionCollectionResolver.page(
            entries: entries,
            from: cursor,
            limit: limit,
            context: context
        )
    }

    /// The promoted row's titles, as hero slides. Titles whose backdrop hasn't
    /// been fetched yet are held back rather than shown as a stretched poster;
    /// `refreshHeroArtwork` fills them in and they appear on the next pass.
    var heroItems: [HeroItem] {
        // Observed so the hero recomputes once enrichment fills in backdrops.
        _ = heroArtworkRevision
        return heroCandidates
            .filter(\.hasWideArtwork)
            .prefix(Self.heroLimit)
            .map(\.self)
    }

    /// Everything the promoted row resolved to, artwork or not.
    var heroCandidates: [HeroItem] {
        guard let heroRef else { return [] }
        return items(for: heroRef).compactMap { item in
            let presentation = heroPresentationOverrides[item.id]
            return HeroItem(
                item: item,
                backdropPath: presentation?.backdropPath,
                logoPath: presentation?.logoPath,
                overview: presentation?.overview
            )
        }
    }

    /// True once every remote row has settled, so a surface can tell "still
    /// loading" from "genuinely empty" before showing an empty state.
    var isSettled: Bool {
        trendingState.isSettled && watchlistState.isSettled && customState.isSettled
    }

    /// The hero's explicit UI state. Views reserve its large first-frame slot
    /// only while this says it may still produce content; a terminal empty or
    /// failed source lets the rows move up instead of leaving a blank expanse.
    var heroState: HeroLoadState {
        guard let heroRef else { return .disabled }
        if !heroItems.isEmpty { return .content }

        switch loadState(for: heroRef) {
        case .idle, .loading, .cached:
            return .loading
        case .failed:
            return .failed
        case .loaded:
            if failedSections.contains(heroRef) { return .failed }
            // A resolved list with no local matches is genuinely empty. When
            // it has matches but still no wide artwork after enrichment, the
            // hero itself failed even though its ordinary row remains usable.
            return items(for: heroRef).isEmpty ? .empty : .failed
        }
    }

    private func loadState(for section: HomeSectionRef) -> HomeLoadState {
        switch section {
        case let .builtin(section):
            switch section {
            case .trendingMovies, .trendingSeries: trendingState
            case .traktWatchlist: watchlistState
            // Sports has its own pipeline (`SportsFollowService`/`SportsStore`) —
            // this feed never fetches it, so there is nothing here to wait on.
            case .recentlyWatched, .favorites, .recentlyAdded, .forYou, .sports: .loaded
            }
        case .custom:
            customState
        }
    }

    // MARK: - Trending

    func loadTrending(cacheKey: String) async {
        let request = loadGate.begin(.trending)
        let cached = restoreTrending(cacheKey: cacheKey)
        trendingState = cached == .missing ? .loading : .cached
        if cached == .fresh {
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: .trending) else { return }
            failedSections.remove(.builtin(.trendingMovies))
            failedSections.remove(.builtin(.trendingSeries))
            trendingState = .loaded
            return
        }
        guard let context else {
            finishTrendingFailure(cached: cached)
            return
        }
        let client = TMDBClient.shared
        guard client.isConfigured else {
            finishTrendingFailure(cached: cached)
            return
        }
        let interval = Perf.begin(.homeTrendingLoad)
        defer { Perf.end(interval) }
        do {
            try await refreshTrending(client: client, context: context, cacheKey: cacheKey, request: request)
        } catch {
            guard loadGate.isCurrent(request, for: .trending) else { return }
            finishTrendingFailure(cached: cached)
        }
    }

    private func refreshTrending(
        client: TMDBClient,
        context: Context,
        cacheKey: String,
        request: SectionFeedLoadGate.Request
    ) async throws {
        let (movies, tvSeries) = try await trendingTitles(using: client)
        guard loadGate.isCurrent(request, for: .trending) else { return }
        let movieCollection = await makeCollection(
            entries: movies.map { HomeListEntry(tmdbId: $0.id, mediaType: .movie, title: $0.title) },
            context: context
        )
        guard loadGate.isCurrent(request, for: .trending) else { return }
        let seriesCollection = await makeCollection(
            entries: tvSeries.map { HomeListEntry(tmdbId: $0.id, mediaType: .series, title: $0.title) },
            context: context
        )
        guard loadGate.isCurrent(request, for: .trending) else { return }
        collections[.builtin(.trendingMovies)] = movieCollection
        collections[.builtin(.trendingSeries)] = seriesCollection
        SectionFeedCache.shared.storeTrending(surface, key: cacheKey, entry: .init(
            movies: movieCollection,
            series: seriesCollection
        ))
        await refreshHeroArtwork()
        guard loadGate.isCurrent(request, for: .trending) else { return }
        failedSections.remove(.builtin(.trendingMovies))
        failedSections.remove(.builtin(.trendingSeries))
        trendingState = .loaded
    }

    private func trendingTitles(using client: TMDBClient) async throws -> ([TrendingTitle], [TrendingTitle]) {
        // A scoped surface only ever renders one medium, so don't pay for the
        // other feed there.
        async let movieTitles = surface.mediaType == .series ? [] : client.trending(.movie)
        async let tvTitles = surface.mediaType == .movie ? [] : client.trending(.tvShow)
        return try await (movieTitles, tvTitles)
    }

    private func restoreTrending(cacheKey: String) -> CacheRestore {
        guard let cached = SectionFeedCache.shared.trendingEntry(surface, for: cacheKey) else { return .missing }
        collections[.builtin(.trendingMovies)] = cached.value.movies
        collections[.builtin(.trendingSeries)] = cached.value.series
        return cached.isFresh ? .fresh : .stale
    }

    private func finishTrendingFailure(cached: CacheRestore) {
        let refs: [HomeSectionRef] = [.builtin(.trendingMovies), .builtin(.trendingSeries)]
        for ref in refs where items(for: ref).isEmpty {
            failedSections.insert(ref)
        }
        trendingState = cached != .missing && refs.contains(where: { !items(for: $0).isEmpty })
            ? .loaded
            : .failed
    }
}

// MARK: - Watchlist and custom sections

extension SectionFeed {
    /// Loads the connected user's Trakt watchlist and keeps only the titles the
    /// user actually owns in the active playlist — matched by TMDB id, the same
    /// way the trending rows work, and narrowed to the surface's medium.
    func loadWatchlist(cacheKey: String) async {
        let request = loadGate.begin(.watchlist)
        let cached = restoreWatchlist(cacheKey: cacheKey)
        watchlistState = cached == .missing ? .loading : .cached
        if cached == .fresh {
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: .watchlist) else { return }
            failedSections.remove(.builtin(.traktWatchlist))
            watchlistState = .loaded
            return
        }
        guard let context else {
            finishWatchlistFailure(cached: cached)
            return
        }
        guard TraktService.shared.isConnected else {
            collections[.builtin(.traktWatchlist)] = .empty
            failedSections.remove(.builtin(.traktWatchlist))
            watchlistState = .loaded
            return
        }
        do {
            let items = try await TraktService.shared.watchlistItems()
            guard loadGate.isCurrent(request, for: .watchlist) else { return }
            let collection = await makeCollection(entries: watchlistEntries(items), context: context)
            guard loadGate.isCurrent(request, for: .watchlist) else { return }
            collections[.builtin(.traktWatchlist)] = collection
            SectionFeedCache.shared.storeWatchlist(surface, key: cacheKey, collection: collection)
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: .watchlist) else { return }
            failedSections.remove(.builtin(.traktWatchlist))
            watchlistState = .loaded
        } catch {
            // Preserve a stale row when revalidation fails. A transport error is
            // not evidence that the remote watchlist became empty.
            if cached == .missing, loadGate.isCurrent(request, for: .watchlist) {
                collections[.builtin(.traktWatchlist)] = .empty
            }
            guard loadGate.isCurrent(request, for: .watchlist) else { return }
            finishWatchlistFailure(cached: cached)
        }
    }

    private func restoreWatchlist(cacheKey: String) -> CacheRestore {
        guard let cached = SectionFeedCache.shared.watchlistEntry(surface, for: cacheKey) else { return .missing }
        collections[.builtin(.traktWatchlist)] = cached.value
        return cached.isFresh ? .fresh : .stale
    }

    private func finishWatchlistFailure(cached: CacheRestore) {
        let ref = HomeSectionRef.builtin(.traktWatchlist)
        if cached != .missing, !items(for: ref).isEmpty {
            watchlistState = .loaded
        } else {
            failedSections.insert(ref)
            watchlistState = .failed
        }
    }

    private func watchlistEntries(_ items: [TraktWatchlistItem]) -> [HomeListEntry] {
        items.compactMap { item in
            switch item.type {
            case "movie":
                guard let media = item.movie, let tmdbId = media.ids.tmdb else { return nil }
                return HomeListEntry(tmdbId: tmdbId, mediaType: .movie, title: media.title ?? "")
            case "show":
                guard let media = item.show, let tmdbId = media.ids.tmdb else { return nil }
                return HomeListEntry(tmdbId: tmdbId, mediaType: .series, title: media.title ?? "")
            default:
                return nil
            }
        }
    }

    // MARK: - Custom sections

    /// Fetches every visible custom list concurrently and publishes each
    /// 20-card preview as soon as that source resolves. The full lightweight
    /// source remains in the snapshot for later pages.
    func loadCustomSections(cacheKey: String, sections: [CustomHomeSection]) async {
        let request = loadGate.begin(.custom)
        guard !sections.isEmpty else {
            replaceCustomCollections(with: [:])
            failedSections = failedSections.filter { ref in
                if case .custom = ref { return false }
                return true
            }
            customState = .loaded
            return
        }
        let cached = restoreCustom(cacheKey: cacheKey)
        customState = cached.state == .missing ? .loading : .cached
        if cached.state == .fresh {
            // A recreated surface has a new transient presentation map even
            // though the session memo can restore its collection models. Run
            // enrichment before returning so a hero selected in Settings does
            // not remain empty until those models are rebuilt on app launch.
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: .custom) else { return }
            for section in sections {
                failedSections.remove(.custom(section.id))
            }
            customState = .loaded
            return
        }
        guard let context else {
            finishCustomFailure(sections: sections, cached: cached.collections)
            return
        }

        let interval = Perf.begin(.homeCustomSections)
        defer { Perf.end(interval) }

        guard let result = await resolveCustomListsProgressively(
            sections,
            fallback: cached.collections,
            context: context,
            request: request
        ) else { return }
        await refreshHeroArtwork()

        // Only memo a complete pass. Caching a row that failed to load (offline
        // at launch, provider down) would leave it empty for the whole session,
        // since the cache key doesn't change until the catalog or the sections do.
        guard loadGate.isCurrent(request, for: .custom) else { return }
        updateCustomFailures(sections: sections, lists: result.lists, fallback: cached.collections)
        customState = .loaded
        guard sections.allSatisfy({ (result.lists[$0.id] ?? nil) != nil }) else { return }
        SectionFeedCache.shared.storeCustom(surface, key: cacheKey, collections: result.collections)
    }

    private func resolveCustomListsProgressively(
        _ sections: [CustomHomeSection],
        fallback: [UUID: SectionCollectionSnapshot],
        context: Context,
        request: SectionFeedLoadGate.Request
    ) async -> (lists: [UUID: [HomeListEntry]?], collections: [UUID: SectionCollectionSnapshot])? {
        let sectionsByID = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
        let visibleIDs = Set(sectionsByID.keys)
        var resolved = fallback.filter { visibleIDs.contains($0.key) }
        replaceCustomCollections(with: resolved)

        return await withTaskGroup(of: (UUID, [HomeListEntry]?, String?).self) { group in
            for section in sections {
                group.addTask {
                    do {
                        return try await (section.id, HomeListCatalog.entries(for: section.sourceURL), nil)
                    } catch {
                        // A failed fetch is nil, not an empty list — a stale
                        // snapshot remains usable when the provider is offline.
                        return (section.id, nil, error.localizedDescription)
                    }
                }
            }
            var lists: [UUID: [HomeListEntry]?] = [:]
            for await (id, entries, failure) in group {
                guard loadGate.isCurrent(request, for: .custom) else {
                    group.cancelAll()
                    return nil
                }
                lists[id] = entries

                guard let entries else {
                    if resolved[id] == nil {
                        resolved[id] = .empty
                        collections[.custom(id)] = .empty
                    }
                    logCustomSectionFailure(failure, section: sectionsByID[id])
                    continue
                }

                let collection = await makeCollection(entries: entries, context: context)
                guard loadGate.isCurrent(request, for: .custom) else {
                    group.cancelAll()
                    return nil
                }
                resolved[id] = collection
                collections[.custom(id)] = collection
                failedSections.remove(.custom(id))

                // A custom hero should not wait for an unrelated slow list.
                // Finish its bounded artwork pass as soon as its own source is
                // available; other rails have already been fetching in parallel.
                if heroRef == .custom(id) {
                    await refreshHeroArtwork()
                    guard loadGate.isCurrent(request, for: .custom) else {
                        group.cancelAll()
                        return nil
                    }
                }
            }
            return (lists, resolved)
        }
    }

    private func logCustomSectionFailure(_ failure: String?, section: CustomHomeSection?) {
        guard let failure, let section else { return }
        Logger.network.warning(
            "Custom section \(section.title, privacy: .private) failed: \(failure, privacy: .public)"
        )
    }

    private func restoreCustom(
        cacheKey: String
    ) -> (state: CacheRestore, collections: [UUID: SectionCollectionSnapshot]) {
        guard let cached = SectionFeedCache.shared.customEntry(surface, for: cacheKey) else {
            return (.missing, [:])
        }
        replaceCustomCollections(with: cached.value)
        return (cached.isFresh ? .fresh : .stale, cached.value)
    }

    private func finishCustomFailure(
        sections: [CustomHomeSection],
        cached: [UUID: SectionCollectionSnapshot]
    ) {
        for section in sections where cached[section.id]?.preview.isEmpty != false {
            failedSections.insert(.custom(section.id))
        }
        customState = cached.values.contains(where: { !$0.preview.isEmpty }) ? .loaded : .failed
    }

    private func updateCustomFailures(
        sections: [CustomHomeSection],
        lists: [UUID: [HomeListEntry]?],
        fallback: [UUID: SectionCollectionSnapshot]
    ) {
        for section in sections {
            let ref = HomeSectionRef.custom(section.id)
            let failedWithoutCache = (lists[section.id] ?? nil) == nil
                && fallback[section.id]?.preview.isEmpty != false
            if failedWithoutCache {
                failedSections.insert(ref)
            } else {
                failedSections.remove(ref)
            }
        }
    }
}

// MARK: - Context plumbing

extension SectionFeed {
    /// Set by the surface before each load. Held rather than passed to every
    /// call so the `.task` sites stay as short as they were when this logic
    /// lived on `HomeView`.
    func update(context: Context) {
        let previousIdentity = self.context.map(contextIdentity)
        let nextIdentity = contextIdentity(context)
        self.context = context
        guard previousIdentity != nil, previousIdentity != nextIdentity else { return }

        // Catalog models belong to the previous playlist/visibility scope. Drop
        // them before the new tasks restore matching cache entries, and revoke
        // every in-flight request so an A → B → A switch cannot publish late.
        loadGate.invalidateAll()
        collections.removeAll()
        heroPresentationOverrides.removeAll()
        heroEnrichmentIDs.removeAll()
        failedSections.removeAll()
        heroArtworkRevision &+= 1
        trendingState = .idle
        watchlistState = .idle
        customState = .idle
    }

    private func contextIdentity(_ context: Context) -> String {
        "\(context.playlistPrefix ?? "*")|\(context.restriction.visibilityToken)"
    }

    private func makeCollection(
        entries: [HomeListEntry],
        context: Context
    ) async -> SectionCollectionSnapshot {
        await SectionCollectionResolver.snapshot(
            entries: entries,
            mediaType: surface.mediaType,
            context: context,
            previewLimit: Self.itemLimit
        )
    }

    private func replaceCustomCollections(with custom: [UUID: SectionCollectionSnapshot]) {
        collections = collections.filter { key, _ in
            if case .custom = key { return false }
            return true
        }
        for (id, collection) in custom {
            collections[.custom(id)] = collection
        }
    }
}

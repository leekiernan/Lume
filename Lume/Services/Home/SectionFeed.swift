//
//  SectionFeed.swift
//  Lume
//
//  The remote-backed rows shared by every section surface (Home, Movies,
//  Series): TMDB trending, the Trakt/Simkl watchlists, and the user's custom list
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
    private typealias CacheRestore = SectionFeedLoadMachine.CacheHit

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
    /// Every source's load state and the catalog scope they were matched in —
    /// see `SectionFeedLoadMachine`. Only `transition(_:)` advances it.
    private(set) var loads = SectionFeedLoadMachine()
    /// The custom sections last asked for, so a scope change can reload them.
    private var requestedCustomSections: [CustomHomeSection] = []
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
        loads.isSettled
    }

    /// The hero's explicit UI state. Views reserve its large first-frame slot
    /// only while this says it may still produce content; a terminal empty or
    /// failed source lets the rows move up instead of leaving a blank expanse.
    var heroState: HeroLoadState {
        loads.heroState(
            for: heroRef,
            hasSlides: !heroItems.isEmpty,
            rowHasItems: heroRef.map { !items(for: $0).isEmpty } ?? false
        )
    }

    // MARK: - Trending

    func loadTrending(cacheKey: String) async {
        let request = loadGate.begin(.trending)
        let cached = restoreTrending(cacheKey: cacheKey)
        transition(.began(.trending, key: cacheKey, cache: cached))
        if cached == .fresh {
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: .trending) else { return }
            transition(.rowsRecovered([.builtin(.trendingMovies), .builtin(.trendingSeries)]))
            transition(.finished(.trending, .loaded))
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
        logMatch("trending movies", movieCollection)
        logMatch("trending series", seriesCollection)
        SectionFeedCache.shared.storeTrending(surface, key: scoped(cacheKey), entry: .init(
            movies: movieCollection,
            series: seriesCollection
        ))
        await refreshHeroArtwork()
        guard loadGate.isCurrent(request, for: .trending) else { return }
        transition(.rowsRecovered([.builtin(.trendingMovies), .builtin(.trendingSeries)]))
        transition(.finished(.trending, .loaded))
    }

    private func trendingTitles(using client: TMDBClient) async throws -> ([TrendingTitle], [TrendingTitle]) {
        // A scoped surface only ever renders one medium, so don't pay for the
        // other feed there.
        async let movieTitles = surface.mediaType == .series ? [] : client.trending(.movie)
        async let tvTitles = surface.mediaType == .movie ? [] : client.trending(.tvShow)
        return try await (movieTitles, tvTitles)
    }

    private func restoreTrending(cacheKey: String) -> CacheRestore {
        guard let cached = SectionFeedCache.shared.trendingEntry(surface, for: scoped(cacheKey)) else { return .missing }
        collections[.builtin(.trendingMovies)] = cached.value.movies
        collections[.builtin(.trendingSeries)] = cached.value.series
        return cached.isFresh ? .fresh : .stale
    }

    private func finishTrendingFailure(cached: CacheRestore) {
        let refs: [HomeSectionRef] = [.builtin(.trendingMovies), .builtin(.trendingSeries)]
        for ref in refs where items(for: ref).isEmpty {
            transition(.rowsFailed([ref]))
        }
        let usable = cached != .missing && refs.contains(where: { !items(for: $0).isEmpty })
        transition(.finished(.trending, usable ? .loaded : .failed))
    }
}

// MARK: - Watchlist and custom sections

extension SectionFeed {
    /// Loads the connected user's watchlist from `provider` and keeps only the
    /// titles the user actually owns in the active playlist — matched by TMDB
    /// id, the same way the trending rows work, and narrowed to the surface's
    /// medium.
    func loadWatchlist(_ provider: WatchlistProvider, cacheKey: String) async {
        let ref = HomeSectionRef.builtin(provider.section)
        let feed = SectionFeedSource.watchlist(provider)
        let request = loadGate.begin(feed)
        let cached = restoreWatchlist(provider, cacheKey: cacheKey)
        transition(.began(feed, key: cacheKey, cache: cached))
        if cached == .fresh {
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: feed) else { return }
            transition(.rowsRecovered([ref]))
            transition(.finished(.watchlist(provider), .loaded))
            return
        }
        guard let context else {
            finishWatchlistFailure(provider, cached: cached)
            return
        }
        guard provider.isConnected else {
            collections[ref] = .empty
            transition(.rowsRecovered([ref]))
            transition(.finished(.watchlist(provider), .loaded))
            return
        }
        do {
            let entries = try await provider.entries()
            guard loadGate.isCurrent(request, for: feed) else { return }
            let collection = await makeCollection(entries: entries, context: context)
            guard loadGate.isCurrent(request, for: feed) else { return }
            collections[ref] = collection
            logMatch("\(provider) watchlist", collection)
            SectionFeedCache.shared.storeWatchlist(surface, provider, key: scoped(cacheKey), collection: collection)
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: feed) else { return }
            transition(.rowsRecovered([ref]))
            transition(.finished(.watchlist(provider), .loaded))
        } catch {
            // Preserve a stale row when revalidation fails. A transport error is
            // not evidence that the remote watchlist became empty.
            if cached == .missing, loadGate.isCurrent(request, for: feed) {
                collections[ref] = .empty
            }
            guard loadGate.isCurrent(request, for: feed) else { return }
            finishWatchlistFailure(provider, cached: cached)
        }
    }

    private func restoreWatchlist(_ provider: WatchlistProvider, cacheKey: String) -> CacheRestore {
        guard let cached = SectionFeedCache.shared.watchlistEntry(surface, provider, for: scoped(cacheKey)) else {
            return .missing
        }
        collections[.builtin(provider.section)] = cached.value
        return cached.isFresh ? .fresh : .stale
    }

    private func finishWatchlistFailure(_ provider: WatchlistProvider, cached: CacheRestore) {
        let ref = HomeSectionRef.builtin(provider.section)
        if cached != .missing, !items(for: ref).isEmpty {
            transition(.finished(.watchlist(provider), .loaded))
        } else {
            transition(.rowsFailed([ref]))
            transition(.finished(.watchlist(provider), .failed))
        }
    }

    // MARK: - Custom sections

    /// Fetches every visible custom list concurrently and publishes each
    /// 20-card preview as soon as that source resolves. The full lightweight
    /// source remains in the snapshot for later pages.
    func loadCustomSections(cacheKey: String, sections: [CustomHomeSection]) async {
        let request = loadGate.begin(.custom)
        requestedCustomSections = sections
        guard !sections.isEmpty else {
            transition(.began(.custom, key: cacheKey, cache: .missing))
            replaceCustomCollections(with: [:])
            transition(.rowsRecovered(Array(loads.failedRows.filter { SectionFeedSource(row: $0) == .custom })))
            transition(.finished(.custom, .loaded))
            return
        }
        let cached = restoreCustom(cacheKey: cacheKey)
        transition(.began(.custom, key: cacheKey, cache: cached.state))
        if cached.state == .fresh {
            // A recreated surface has a new transient presentation map even
            // though the session memo can restore its collection models. Run
            // enrichment before returning so a hero selected in Settings does
            // not remain empty until those models are rebuilt on app launch.
            await refreshHeroArtwork()
            guard loadGate.isCurrent(request, for: .custom) else { return }
            for section in sections {
                transition(.rowsRecovered([.custom(section.id)]))
            }
            transition(.finished(.custom, .loaded))
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
        transition(.finished(.custom, .loaded))
        guard sections.allSatisfy({ (result.lists[$0.id] ?? nil) != nil }) else { return }
        SectionFeedCache.shared.storeCustom(surface, key: scoped(cacheKey), collections: result.collections)
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
                logMatch("custom list", collection)
                transition(.rowsRecovered([.custom(id)]))

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
        guard let cached = SectionFeedCache.shared.customEntry(surface, for: scoped(cacheKey)) else {
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
            transition(.rowsFailed([.custom(section.id)]))
        }
        let usable = cached.values.contains(where: { !$0.preview.isEmpty })
        transition(.finished(.custom, usable ? .loaded : .failed))
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
                transition(.rowsFailed([ref]))
            } else {
                transition(.rowsRecovered([ref]))
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
        self.context = context
        transition(.contextChanged(identity: contextIdentity(context)))
    }

    private func contextIdentity(_ context: Context) -> String {
        "\(context.playlistPrefix ?? "*")|\(context.restriction.visibilityToken)"
    }

    /// A session-cache key scoped to the catalog it was matched against. The
    /// cached collections hold models from that scope, so a key the view
    /// happens to reuse after a scope change must not find them.
    private func scoped(_ cacheKey: String) -> String {
        "\(loads.contextIdentity ?? "*")|\(cacheKey)"
    }

    /// How a resolved list met the catalog. "0 shown, 20 of 20 checked" means
    /// the list arrived but none of it matched — a catalog without TMDB ids, or
    /// the wrong playlist scope — which is otherwise indistinguishable on screen
    /// from a list that never loaded.
    private func logMatch(_ label: String, _ collection: SectionCollectionSnapshot) {
        Logger.home.info(
            "\(surface.rawValue) \(label): \(collection.preview.count) shown, \(collection.nextOffset) of \(collection.entries.count) checked"
        )
    }

    /// The one way load state changes: applies `event`, journals the
    /// transition, and performs what the machine asks for.
    private func transition(_ event: SectionFeedLoadMachine.Event) {
        let source: SectionFeedSource? = switch event {
        case let .began(source, _, _), let .finished(source, _): source
        case .contextChanged, .rowsFailed, .rowsRecovered: nil
        }
        let before = source.map(loads.state(of:))
        guard source.map({ SectionFeedLoadMachine.isValid(event, in: loads.state(of: $0)) }) ?? true else {
            Logger.home.warning("\(surface.rawValue) \(String(describing: source)): ignored \(String(describing: event)) while \(String(describing: before))")
            return
        }
        let failedBefore = loads.failedRows
        let effects = loads.handle(event)
        for row in loads.failedRows.subtracting(failedBefore) {
            Logger.home.notice("\(surface.rawValue) row \(row.token): failed with nothing cached")
        }
        for row in failedBefore.subtracting(loads.failedRows) {
            Logger.home.info("\(surface.rawValue) row \(row.token): recovered")
        }
        if let source, let before {
            Logger.home.info("\(surface.rawValue) \(source): \(before) → \(loads.state(of: source))")
        }
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: SectionFeedLoadMachine.Effect) {
        switch effect {
        case .discardCatalogModels:
            // Catalog models belong to the previous playlist/visibility scope.
            // Drop them, and revoke every in-flight request so an A → B → A
            // switch cannot publish late.
            Logger.home.info("\(surface.rawValue): catalog scope changed; discarding matched rows")
            loadGate.invalidateAll()
            collections.removeAll()
            heroPresentationOverrides.removeAll()
            heroEnrichmentIDs.removeAll()
            heroArtworkRevision &+= 1
        case let .reload(source, key):
            // Usually the view's own tasks re-run for the new scope and begin
            // these loads themselves; give them a moment, then load whatever is
            // still idle so no source is left empty because its task didn't.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, loads.state(of: source) == .idle else { return }
                Logger.home.notice("\(surface.rawValue) \(source): reloading after scope change")
                switch source {
                case .trending: await loadTrending(cacheKey: key)
                case let .watchlist(provider): await loadWatchlist(provider, cacheKey: key)
                case .custom: await loadCustomSections(cacheKey: key, sections: requestedCustomSections)
                }
            }
        }
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

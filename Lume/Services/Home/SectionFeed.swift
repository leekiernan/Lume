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

import SwiftData
import SwiftUI

@MainActor
@Observable
final class SectionFeed {
    private enum HeroArtworkKind {
        case movie
        case series
    }

    private struct HeroArtworkRequest {
        let id: String
        let heroID: String
        let tmdbId: Int
        let kind: HeroArtworkKind
        let needsBackdrop: Bool
    }

    private struct HeroPresentation {
        let backdropPath: String?
        let logoPath: String?
        let overview: String?

        init(_ details: TMDBTitleDetails) {
            backdropPath = details.backdropPath
            logoPath = details.logoPath
            overview = details.overview
        }
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
    private(set) var heroArtworkRevision = 0
    /// Fresh TMDB paths used immediately while the view context still holds the
    /// pre-enrichment version of a model. The same details are persisted by the
    /// enrichment actor for subsequent launches.
    private var heroPresentationOverrides: [String: HeroPresentation] = [:]
    /// Prevents the independent trending, watchlist and custom-section loaders
    /// from requesting the same hero enrichment while another loader is still
    /// waiting for it.
    private var heroEnrichmentIDs: Set<String> = []
    /// Every remote-backed row shares one representation: its lightweight
    /// ordered source plus a bounded catalog preview. The source tail remains
    /// available for an incrementally-loaded full grid without keeping all of
    /// its SwiftData models alive on the browse screen.
    private(set) var collections: [HomeSectionRef: SectionCollectionSnapshot] = [:]
    private(set) var trendingState: HomeLoadState = .idle

    /// How many matched titles a remote-backed row shows.
    static let itemLimit = 20
    /// How many hero candidates the Home carousel pages through.
    private static let heroLimit = 8

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
        return await SectionCollectionResolver.page(
            entries: collection.entries,
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
    private var heroCandidates: [HeroItem] {
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
        trendingState.isSettled
    }

    // MARK: - Trending

    func loadTrending(cacheKey: String) async {
        // Session cache: see `SectionFeedCache`.
        if let cached = SectionFeedCache.shared.trendingEntry(surface, for: cacheKey) {
            collections[.builtin(.trendingMovies)] = cached.movies
            collections[.builtin(.trendingSeries)] = cached.series
            trendingState = .loaded
            await refreshHeroArtwork()
            return
        }
        guard let context else { return }
        let client = TMDBClient.shared
        guard client.isConfigured else {
            trendingState = .loaded
            return
        }
        trendingState = .loading
        let interval = Perf.begin(.homeTrendingLoad)
        defer { Perf.end(interval) }
        do {
            // A scoped surface only ever renders one medium, so don't pay for
            // the other feed there.
            async let movieTitles = surface.mediaType == .series ? [] : client.trending(.movie)
            async let tvTitles = surface.mediaType == .movie ? [] : client.trending(.tvShow)
            let (movies, tvSeries) = try await (movieTitles, tvTitles)

            let movieCollection = await makeCollection(
                entries: movies.map {
                    HomeListEntry(tmdbId: $0.id, mediaType: .movie, title: $0.title)
                },
                context: context
            )
            let seriesCollection = await makeCollection(
                entries: tvSeries.map {
                    HomeListEntry(tmdbId: $0.id, mediaType: .series, title: $0.title)
                },
                context: context
            )
            guard !Task.isCancelled else { return }
            collections[.builtin(.trendingMovies)] = movieCollection
            collections[.builtin(.trendingSeries)] = seriesCollection
            trendingState = .loaded
            SectionFeedCache.shared.storeTrending(surface, key: cacheKey, entry: .init(
                movies: movieCollection,
                series: seriesCollection
            ))
            await refreshHeroArtwork()
        } catch {
            trendingState = .failed
        }
    }

    /// The TMDB trending feed carries no logo artwork, so a hero title shows
    /// only its backdrop until its full details are fetched.
    /// A promoted section has neither: its entries are just ids, so the hero
    /// depends entirely on what enrichment has stored on the catalog model. That fetch used to
    /// happen only on the detail screen, so logos "popped in" after visiting
    /// Details and coming back. Enrich the visible hero titles up front via the
    /// same TMDB detail path. Runs after the carousel is shown so backdrops
    /// aren't blocked.
    /// Fetches the wide artwork, logo and copy for hero candidates that are
    /// missing any of it, on the sync manager's background context. The saves
    /// auto-merge, so the hero picks them up without a main-thread store write.
    /// A hero needs a fetch when it is missing its wide artwork or its logo and
    /// hasn't been enriched recently. The recency guard mirrors the detail
    /// screen's 14-day window so titles TMDB simply has no backdrop or logo for
    /// aren't refetched on every appearance — `tmdbEnrichedAt` is stamped only
    /// on a successful fetch, so "enriched but still no backdrop" genuinely
    /// means TMDB has none, which is the only case the hero holds back.
    private static func heroNeedsArtwork(backdropPath: String?, logoPath: String?, enrichedAt: Date?) -> Bool {
        guard (backdropPath ?? "").isEmpty || (logoPath ?? "").isEmpty else { return false }
        guard let enrichedAt else { return true }
        return Date().timeIntervalSince(enrichedAt) >= 14 * 24 * 3600
    }

    // MARK: - Watchlist

    /// Loads the connected user's Trakt watchlist and keeps only the titles the
    /// user actually owns in the active playlist — matched by TMDB id, the same
    /// way the trending rows work, and narrowed to the surface's medium.
    func loadWatchlist(cacheKey: String) async {
        if let cached = SectionFeedCache.shared.watchlistEntry(surface, for: cacheKey) {
            collections[.builtin(.traktWatchlist)] = cached
            await refreshHeroArtwork()
            return
        }
        guard let context else { return }
        guard TraktService.shared.isConnected else {
            collections[.builtin(.traktWatchlist)] = .empty
            return
        }
        let items = await TraktService.shared.fetchWatchlist()
        let entries = items.compactMap { item -> HomeListEntry? in
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
        let collection = await makeCollection(entries: entries, context: context)
        guard !Task.isCancelled else { return }
        collections[.builtin(.traktWatchlist)] = collection
        SectionFeedCache.shared.storeWatchlist(surface, key: cacheKey, collection: collection)
        await refreshHeroArtwork()
    }

    // MARK: - Custom sections

    /// Fetches every visible custom list concurrently, then resolves only its
    /// 20-card preview against the local catalog. The full lightweight source
    /// remains in the snapshot for later pages.
    func loadCustomSections(cacheKey: String, sections: [CustomHomeSection]) async {
        guard !sections.isEmpty else {
            replaceCustomCollections(with: [:])
            return
        }
        if let cached = SectionFeedCache.shared.customEntry(surface, for: cacheKey) {
            replaceCustomCollections(with: cached)
            // A recreated surface has a new transient presentation map even
            // though the session memo can restore its collection models. Run
            // enrichment before returning so a hero selected in Settings does
            // not remain empty until those models are rebuilt on app launch.
            await refreshHeroArtwork()
            return
        }
        guard let context else { return }

        let interval = Perf.begin(.homeCustomSections)
        defer { Perf.end(interval) }

        let lists = await withTaskGroup(of: (UUID, [HomeListEntry]?).self) { group in
            for section in sections {
                group.addTask {
                    // A failed fetch is nil, not an empty list — the two are
                    // handled differently below.
                    await (section.id, try? HomeListCatalog.entries(for: section.sourceURL))
                }
            }
            var results: [UUID: [HomeListEntry]?] = [:]
            for await (id, entries) in group {
                results[id] = entries
            }
            return results
        }

        var resolved: [UUID: SectionCollectionSnapshot] = [:]
        for section in sections {
            resolved[section.id] = await makeCollection(
                entries: (lists[section.id] ?? nil) ?? [],
                context: context
            )
            guard !Task.isCancelled else { return }
        }
        replaceCustomCollections(with: resolved)
        await refreshHeroArtwork()

        // Only memo a complete pass. Caching a row that failed to load (offline
        // at launch, provider down) would leave it empty for the whole session,
        // since the cache key doesn't change until the catalog or the sections do.
        guard sections.allSatisfy({ (lists[$0.id] ?? nil) != nil }) else { return }
        SectionFeedCache.shared.storeCustom(surface, key: cacheKey, collections: resolved)
    }

    /// Fetches wide artwork for at most the carousel's eight visible candidates.
    /// The rest of the preview — and all retained source entries — remain plain
    /// catalog/list data until the user asks to see them.
    private func refreshHeroArtwork() async {
        guard let context, heroRef != nil else { return }
        let candidates = Array(heroCandidates.prefix(Self.heroLimit))
        guard !candidates.isEmpty else { return }

        // On a clean catalog most candidates have only portrait provider art.
        // Build value-only requests before leaving the main actor; managed
        // models must never cross into the task-group children.
        var requests = candidates.compactMap(heroArtworkRequest)
        requests.removeAll { request in
            !heroEnrichmentIDs.insert(request.id).inserted
        }
        guard !requests.isEmpty else { return }
        let enrichmentIDs = requests.map(\.id)
        defer { heroEnrichmentIDs.subtract(enrichmentIDs) }

        // Make an entirely empty hero useful after one request, then finish the
        // remaining bounded set concurrently. Previously all eight ran serially
        // and the sole revision bump came at the end: Movies stayed blank while
        // Home/Series appeared truncated during a cold launch.
        if let firstMissingBackdrop = requests.firstIndex(where: \.needsBackdrop) {
            requests.swapAt(0, firstMissingBackdrop)
        }
        let manager = ContentSyncManager(modelContainer: context.modelContext.container)
        let firstRequest = requests.removeFirst()
        let firstDetails = await enrichHeroArtwork(firstRequest, using: manager)
        publishHeroArtworkChange(heroID: firstRequest.heroID, details: firstDetails)
        guard !Task.isCancelled else { return }

        await enrichRemainingHeroArtwork(requests, using: manager)
    }

    private func enrichRemainingHeroArtwork(
        _ requests: [HeroArtworkRequest],
        using manager: ContentSyncManager
    ) async {
        let concurrency = 2
        for start in stride(from: 0, to: requests.count, by: concurrency) {
            guard !Task.isCancelled else { return }
            let end = min(start + concurrency, requests.count)
            let batch = requests[start ..< end]
            await withTaskGroup(of: (String, TMDBTitleDetails?).self) { group in
                for request in batch {
                    let id = request.id
                    let heroID = request.heroID
                    let tmdbId = request.tmdbId
                    switch request.kind {
                    case .movie:
                        group.addTask {
                            guard !Task.isCancelled else { return (heroID, nil) }
                            let details = await manager.enrichMovie(id: id, tmdbId: tmdbId)
                            return (heroID, details)
                        }
                    case .series:
                        group.addTask {
                            guard !Task.isCancelled else { return (heroID, nil) }
                            let details = await manager.enrichSeries(id: id, tmdbId: tmdbId)
                            return (heroID, details)
                        }
                    }
                }
                for await (heroID, details) in group {
                    publishHeroArtworkChange(heroID: heroID, details: details)
                }
            }
        }
    }

    private func heroArtworkRequest(_ hero: HeroItem) -> HeroArtworkRequest? {
        // An override means this session already fetched the model's currently
        // stale fields; do not let a later feed loader issue the same request.
        guard heroPresentationOverrides[hero.id] == nil else { return nil }
        switch hero {
        case let .movie(movie, _, _, _):
            guard Self.heroNeedsArtwork(
                backdropPath: movie.backdropPath,
                logoPath: movie.logoPath,
                enrichedAt: movie.tmdbEnrichedAt
            ), let tmdbId = movie.tmdbId else { return nil }
            return HeroArtworkRequest(
                id: movie.id,
                heroID: hero.id,
                tmdbId: tmdbId,
                kind: .movie,
                needsBackdrop: (movie.backdropPath ?? "").isEmpty
            )
        case let .series(series, _, _, _):
            guard Self.heroNeedsArtwork(
                backdropPath: series.backdropPath,
                logoPath: series.logoPath,
                enrichedAt: series.tmdbEnrichedAt
            ), let tmdbId = series.tmdbId else { return nil }
            return HeroArtworkRequest(
                id: series.id,
                heroID: hero.id,
                tmdbId: tmdbId,
                kind: .series,
                needsBackdrop: (series.backdropPath ?? "").isEmpty
            )
        }
    }

    private func enrichHeroArtwork(
        _ request: HeroArtworkRequest,
        using manager: ContentSyncManager
    ) async -> TMDBTitleDetails? {
        switch request.kind {
        case .movie:
            await manager.enrichMovie(id: request.id, tmdbId: request.tmdbId)
        case .series:
            await manager.enrichSeries(id: request.id, tmdbId: request.tmdbId)
        }
    }

    /// Render the fetched backdrop from a value snapshot immediately. The view
    /// context may continue serving its stale pre-enrichment model until the
    /// screen or app is recreated, despite the background save succeeding.
    private func publishHeroArtworkChange(heroID: String, details: TMDBTitleDetails?) {
        if let details { heroPresentationOverrides[heroID] = HeroPresentation(details) }
        heroArtworkRevision &+= 1
    }

    // MARK: - Context plumbing

    /// Set by the surface before each load. Held rather than passed to every
    /// call so the `.task` sites stay as short as they were when this logic
    /// lived on `HomeView`.
    private var context: Context?

    func update(context: Context) {
        self.context = context
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

// MARK: - Load state

enum HomeLoadState {
    case idle
    case loading
    case loaded
    case failed

    var isSettled: Bool {
        switch self {
        case .idle, .loading: false
        case .loaded, .failed: true
        }
    }
}

/// `tmdbId` is optional, and neither `?? -1` (TERNARY) nor a nil-check +
/// force-unwrap (ForcedUnwrap) survives SwiftData's SQL generation — both throw
/// at fetch time on a real store (in-memory stores skip SQL and don't
/// reproduce it). Comparing against a `Set<Int?>` builds a plain `IN` clause.
/// Internal (not fileprivate) so tests can run them against a SQLite store.
nonisolated func movieTmdbIdPredicate(ids: Set<Int>) -> Predicate<Movie> {
    let optionalIds = Set(ids.map(Int?.some))
    return #Predicate { optionalIds.contains($0.tmdbId) }
}

nonisolated func seriesTmdbIdPredicate(ids: Set<Int>) -> Predicate<Series> {
    let optionalIds = Set(ids.map(Int?.some))
    return #Predicate { optionalIds.contains($0.tmdbId) }
}

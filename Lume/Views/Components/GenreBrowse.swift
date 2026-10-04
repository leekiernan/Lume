//
//  GenreBrowse.swift
//  Lume
//
//  "Browse by Genre" on the Movies and Series tabs. Genre cuts across the
//  provider categories — a title's genre comes from TMDB/playlist metadata, not
//  the category it lives in — so these surfaces are driven by the title's
//  `genre` string rather than a `categoryId`, mirroring the cross-category
//  library collection rows.
//

import SwiftData
import SwiftUI

// MARK: - Genre derivation

/// Upper bound on the fetch that enumerates a playlist's genres. The genre
/// vocabulary is tiny (a couple dozen names) and saturates almost immediately,
/// so a bounded sample surfaces every genre in practice while keeping the
/// derivation cheap on libraries with tens of thousands of titles — the same
/// trade-off `LibraryCollectionRows` makes for "Recently Added".
nonisolated let genreSampleLimit = 5000

enum GenreDerivation {
    /// Derives the genre list on a background context. The sample fetch hydrates
    /// up to `genreSampleLimit` rows, which ran ~500ms on the *main* thread when
    /// invoked from a view's `.task` (the closure inherits the view's MainActor
    /// isolation) — a visible hitch when opening the tab or after a sync
    /// invalidates the query. Running it off the main thread (and fetching only
    /// the three columns the derivation reads) removes the hang entirely.
    static func movieGenres(in container: ModelContainer, playlistPrefix: String, restriction: ContentRestriction) async -> [String] {
        let excludedCategoryIDs = restriction.excludedCategoryIDs
        return await Task.detached(priority: .userInitiated) {
            let descriptor = movieGenreSampleDescriptor(
                playlistPrefix: playlistPrefix,
                excludedCategoryIDs: excludedCategoryIDs
            )
            let movies = (try? ModelContext(container).fetch(descriptor)) ?? []
            return Self.derive(rows: movies)
        }.value
    }

    static func seriesGenres(in container: ModelContainer, playlistPrefix: String, restriction: ContentRestriction) async -> [String] {
        let excludedCategoryIDs = restriction.excludedCategoryIDs
        return await Task.detached(priority: .userInitiated) {
            let descriptor = seriesGenreSampleDescriptor(
                playlistPrefix: playlistPrefix,
                excludedCategoryIDs: excludedCategoryIDs
            )
            let series = (try? ModelContext(container).fetch(descriptor)) ?? []
            return Self.derive(rows: series)
        }.value
    }

    /// The fetch already scoped the bounded sample to the active playlist and
    /// viewer. Keeping that work in SQLite is a correctness requirement: an
    /// unrelated 5,000-row playlist must not consume the sample before the
    /// active playlist's genres are reached.
    private nonisolated static func derive(rows: [some GenreCarrying]) -> [String] {
        GenreParser.distinctByFrequency(rows.map(\.genre))
    }
}

/// Sample descriptors are internal so on-disk tests can verify that the
/// playlist and visibility predicates remain ahead of the 5,000-row cap.
nonisolated func movieGenreSampleDescriptor(
    playlistPrefix prefix: String,
    excludedCategoryIDs: Set<String>
) -> FetchDescriptor<Movie> {
    let excluded = Set(excludedCategoryIDs.map(String?.some))
    let filtersCategories = !excluded.isEmpty
    var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { movie in
        movie.genre != nil
            && movie.id.starts(with: prefix)
            && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
    })
    descriptor.fetchLimit = genreSampleLimit
    descriptor.propertiesToFetch = [\.genre]
    return descriptor
}

nonisolated func seriesGenreSampleDescriptor(
    playlistPrefix prefix: String,
    excludedCategoryIDs: Set<String>
) -> FetchDescriptor<Series> {
    let excluded = Set(excludedCategoryIDs.map(String?.some))
    let filtersCategories = !excluded.isEmpty
    var descriptor = FetchDescriptor<Series>(predicate: #Predicate { series in
        series.genre != nil
            && series.id.starts(with: prefix)
            && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
    })
    descriptor.fetchLimit = genreSampleLimit
    descriptor.propertiesToFetch = [\.genre]
    return descriptor
}

/// The fields the genre derivation reads off a sampled title. `nonisolated` so
/// `derive` can run on a background context (default isolation is `MainActor`);
/// the witnesses are `@Model` stored properties, which are safe to read off the
/// main thread on a background `ModelContext`. Lets `derive` work over both
/// `Movie` and `Series` without duplicating the scoping logic.
nonisolated protocol GenreCarrying {
    var id: String { get }
    var genre: String? { get }
    var categoryId: String? { get }
}

// The conformances are `nonisolated` too, not just the protocol: under
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor a bare `extension Movie: GenreCarrying`
// declares a main-actor-isolated conformance, which cannot satisfy the
// `Sendable` requirement `scan`'s generic parameter carries.
nonisolated extension Movie: GenreCarrying {}
nonisolated extension Series: GenreCarrying {}

// MARK: - Off-main genre page fetch

/// How many source rows one page load may walk before handing control back to
/// the caller. The re-checks below can empty a whole source page, and each
/// retry is another scan, so a genre whose next few hundred rows are all
/// near-misses would otherwise chain scans until it found something. Five
/// source pages is the bound; the caller resumes from the returned cursor.
private nonisolated let genreScanBudget = 500

/// What one page of a genre grid is fetched for. Plain value type so the
/// off-main fetch takes a single `Sendable` value, mirroring `SearchRequest`.
nonisolated struct GenrePageRequest {
    let genre: String
    /// `"<playlistUUID>-"` — the id prefix every title in the active playlist
    /// shares, matched in SQLite rather than after materialization.
    let playlistPrefix: String
    let excludedCategoryIDs: Set<String>
    /// Where in the source rows to resume; see `GenrePage.scanned`.
    let offset: Int
    let pageSize: Int
}

/// A page's displayable rows — identifiers only, never managed objects, which
/// can't cross actor boundaries — plus the cursor state the view carries
/// forward.
nonisolated struct GenrePage {
    var ids: [PersistentIdentifier] = []
    /// Source rows consumed, which is what the next `fetchOffset` must advance
    /// by: the re-checks drop rows the substring fetch returned, so the
    /// displayed count and the source offset diverge.
    var scanned = 0
    /// The source is exhausted — no further page can exist.
    var reachedEnd = false
}

/// Runs a genre page fetch on a background `ModelContext`, mirroring
/// `SearchFetcher`.
///
/// This used to be a synchronous `fetch` on the *main* context, fired from a
/// grid cell's `onAppear` mid-scroll. `localizedStandardContains` can't use the
/// `genre` index, so every page scanned the table — hundreds of milliseconds
/// per page on a 179k-title playlist, and the retry loop could chain several of
/// those into one frame, which is a watchdog hazard rather than a hitch.
nonisolated enum GenrePageFetcher {
    static func movies(
        container: ModelContainer,
        request: GenrePageRequest,
        sortBy: [SortDescriptor<Movie>]
    ) -> GenrePage {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Movie>(predicate: moviePredicate(request: request), sortBy: sortBy)
        descriptor.fetchLimit = request.pageSize
        // Only `genre` (the exact-token re-check) and `categoryId` (viewer
        // visibility) are read off the fetched rows, so leave the rest
        // unhydrated — the same trade the genre derivation above makes, and it
        // keeps a page of wide rows (plot, cast, artwork paths) out of memory.
        descriptor.propertiesToFetch = [\.genre, \.categoryId]
        return scan(request: request) { (offset: Int) -> [Movie] in
            descriptor.fetchOffset = offset
            return (try? context.fetch(descriptor)) ?? []
        }
    }

    static func series(
        container: ModelContainer,
        request: GenrePageRequest,
        sortBy: [SortDescriptor<Series>]
    ) -> GenrePage {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Series>(predicate: seriesPredicate(request: request), sortBy: sortBy)
        descriptor.fetchLimit = request.pageSize
        descriptor.propertiesToFetch = [\.genre, \.categoryId]
        return scan(request: request) { (offset: Int) -> [Series] in
            descriptor.fetchOffset = offset
            return (try? context.fetch(descriptor)) ?? []
        }
    }

    /// The playlist scope and the hidden-category exclusion run in SQLite, in
    /// the shape `searchMoviePredicate` established, so a page isn't spent on
    /// rows the viewer will never see — the offset used to walk every
    /// playlist's titles and then throw all but one playlist's away.
    /// `starts(with:)` compiles to a range seek on the unique `id` index, which
    /// is the only part of this predicate an index can serve: the genre match
    /// has to stay a substring test because the column holds several free-text
    /// genres per title.
    private static func moviePredicate(request: GenrePageRequest) -> Predicate<Movie> {
        let (genre, prefix) = (request.genre, request.playlistPrefix)
        let excluded = Set(request.excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        return #Predicate { movie in
            movie.id.starts(with: prefix)
                && (movie.genre?.localizedStandardContains(genre) ?? false)
                && (!filtersCategories || movie.categoryId == nil || !excluded.contains(movie.categoryId))
        }
    }

    private static func seriesPredicate(request: GenrePageRequest) -> Predicate<Series> {
        let (genre, prefix) = (request.genre, request.playlistPrefix)
        let excluded = Set(request.excludedCategoryIDs.map(String?.some))
        let filtersCategories = !excluded.isEmpty
        return #Predicate { series in
            series.id.starts(with: prefix)
                && (series.genre?.localizedStandardContains(genre) ?? false)
                && (!filtersCategories || series.categoryId == nil || !excluded.contains(series.categoryId))
        }
    }

    /// Walks source pages from `request.offset` until one yields a displayable
    /// row, the source runs out, or `genreScanBudget` is spent.
    ///
    /// The loop is needed because the in-memory re-checks can empty a whole
    /// source page — `GenreParser` keeps `&` intact, so a tile for "Action"
    /// fetches every "Action & Adventure" title and then drops it again — and
    /// without new trailing items the grid never fires `onLoadMore` again,
    /// stalling pagination. The budget is what bounds it: the caller resumes
    /// from the returned cursor instead of the loop running until it finds
    /// something.
    private static func scan(
        request: GenrePageRequest,
        fetch: (Int) -> [some PersistentModel & GenreCarrying]
    ) -> GenrePage {
        let excluded = request.excludedCategoryIDs
        var page = GenrePage()
        while page.ids.isEmpty, !page.reachedEnd, page.scanned < genreScanBudget {
            let rows = fetch(request.offset + page.scanned)
            page.scanned += rows.count
            if rows.count < request.pageSize { page.reachedEnd = true }
            // The exact-token re-check keeps a substring hit out, and the
            // `excludingRestricted` filter is inlined so this stays
            // `nonisolated` — the same trade `GenreDerivation.derive` makes.
            page.ids = rows
                .filter { GenreParser.contains($0.genre, genre: request.genre) && !excluded.contains($0.categoryId ?? "") }
                .map(\.persistentModelID)
        }
        return page
    }
}

// MARK: - Genre detail grids

/// The full grid of movies in a genre, reachable from a genre tile. The fetch
/// narrows to candidate rows in SQLite with `localizedStandardContains`, then
/// re-filters to exact-token matches so substrings can't sneak in — all of it
/// on a background context (`GenrePageFetcher`), because the grid asks for the
/// next page from a cell's `onAppear`, mid-scroll.
typealias MovieGenreView = CatalogGenreView<MovieCatalog>
typealias SeriesGenreView = CatalogGenreView<SeriesCatalog>

//
//  SectionCollection.swift
//  Lume
//
//  A remote section is two things: a lightweight ordered list of TMDB ids and
//  a small window of local catalog models resolved from those ids. Keeping the
//  two separate lets a Home rail stay capped without throwing away the source
//  collection a future full grid can page through.
//

import SwiftData

/// Session-lived state for one remote-backed section. `entries` are cheap value
/// types; only `preview` contains live SwiftData models (and therefore anything
/// an artwork view could observe or request).
struct SectionCollectionSnapshot {
    let entries: [HomeListEntry]
    let preview: [HomeMediaItem]
    /// The first source entry the next catalog page should inspect.
    let nextOffset: Int

    var hasMoreCandidates: Bool {
        nextOffset < entries.count
    }

    static let empty = SectionCollectionSnapshot(entries: [], preview: [], nextOffset: 0)
}

/// A resolved window returned to a section preview or, later, a full collection
/// grid. `hasMoreCandidates` is deliberately conservative: the uninspected tail
/// may contain catalog matches, so callers can ask for another page without us
/// hydrating it merely to calculate an exact count.
struct SectionCollectionPage {
    let items: [HomeMediaItem]
    let nextOffset: Int
    let hasMoreCandidates: Bool
}

@MainActor
enum SectionCollectionResolver {
    /// Bounds every SwiftData `IN` query even when an MDBList contains thousands
    /// of ids. Sparse catalogs may inspect several batches to fill a preview,
    /// but only one bounded set of matching models is materialised at a time.
    static let lookupBatchSize = 100

    static func snapshot(
        entries: [HomeListEntry],
        mediaType: HomeListEntry.MediaType?,
        context: SectionFeed.Context,
        previewLimit: Int
    ) -> SectionCollectionSnapshot {
        let normalized = normalizedEntries(entries, mediaType: mediaType)
        let page = page(entries: normalized, from: 0, limit: previewLimit, context: context)
        return SectionCollectionSnapshot(
            entries: normalized,
            preview: page.items,
            nextOffset: page.nextOffset
        )
    }

    static func page(
        entries: [HomeListEntry],
        from cursor: Int,
        limit: Int,
        context: SectionFeed.Context
    ) -> SectionCollectionPage {
        var offset = min(max(cursor, 0), entries.count)
        guard limit > 0, offset < entries.count else {
            return SectionCollectionPage(items: [], nextOffset: offset, hasMoreCandidates: false)
        }

        var items: [HomeMediaItem] = []
        while offset < entries.count, items.count < limit {
            let upperBound = min(offset + lookupBatchSize, entries.count)
            let batch = entries[offset ..< upperBound]
            let movies = fetchMovies(
                tmdbIds: batch.filter { $0.mediaType == .movie }.map(\.tmdbId),
                context: context
            )
            let series = fetchSeries(
                tmdbIds: batch.filter { $0.mediaType == .series }.map(\.tmdbId),
                context: context
            )

            while offset < upperBound, items.count < limit {
                let entry = entries[offset]
                offset += 1
                switch entry.mediaType {
                case .movie:
                    if let movie = movies[entry.tmdbId] { items.append(.movie(movie)) }
                case .series:
                    if let show = series[entry.tmdbId] { items.append(.series(show)) }
                }
            }
        }

        return SectionCollectionPage(
            items: items,
            nextOffset: offset,
            hasMoreCandidates: offset < entries.count
        )
    }

    /// Applies the surface's medium filter once and removes duplicate title ids
    /// while preserving the source's ordering. That makes cursors stable across
    /// pages and avoids needing a growing "seen" set in a full grid.
    static func normalizedEntries(
        _ entries: [HomeListEntry],
        mediaType: HomeListEntry.MediaType?
    ) -> [HomeListEntry] {
        struct Identity: Hashable {
            let tmdbId: Int
            let mediaType: HomeListEntry.MediaType
        }

        var seen = Set<Identity>()
        return entries.filter { entry in
            guard mediaType == nil || entry.mediaType == mediaType else { return false }
            return seen.insert(Identity(tmdbId: entry.tmdbId, mediaType: entry.mediaType)).inserted
        }
    }

    private static func fetchMovies(
        tmdbIds: [Int],
        context: SectionFeed.Context
    ) -> [Int: Movie] {
        let ids = Set(tmdbIds)
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Movie>(predicate: movieTmdbIdPredicate(ids: ids))
        var byId: [Int: Movie] = [:]
        for movie in (try? context.modelContext.fetch(descriptor)) ?? []
            where context.belongsToActivePlaylist(movie.id)
            && !context.restriction.hides(categoryID: movie.categoryId)
        {
            guard let tmdbId = movie.tmdbId, byId[tmdbId] == nil else { continue }
            byId[tmdbId] = movie
        }
        return byId
    }

    private static func fetchSeries(
        tmdbIds: [Int],
        context: SectionFeed.Context
    ) -> [Int: Series] {
        let ids = Set(tmdbIds)
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Series>(predicate: seriesTmdbIdPredicate(ids: ids))
        var byId: [Int: Series] = [:]
        for show in (try? context.modelContext.fetch(descriptor)) ?? []
            where context.belongsToActivePlaylist(show.id)
            && !context.restriction.hides(categoryID: show.categoryId)
        {
            guard let tmdbId = show.tmdbId, byId[tmdbId] == nil else { continue }
            byId[tmdbId] = show
        }
        return byId
    }
}

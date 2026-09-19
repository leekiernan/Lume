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

/// A catalog match safe to carry from a background `ModelContext` back to the
/// view context. Managed models themselves never cross that boundary.
private nonisolated enum SectionCollectionMatch {
    case movie(PersistentIdentifier)
    case series(PersistentIdentifier)
}

private nonisolated struct SectionCollectionResolution {
    let matches: [SectionCollectionMatch]
    let nextOffset: Int
    let hasMoreCandidates: Bool
}

private nonisolated struct SectionCollectionRequest {
    let entries: [HomeListEntry]
    let cursor: Int
    let limit: Int
    let playlistPrefix: String?
    let excludedCategoryIDs: Set<String>
}

@MainActor
enum SectionCollectionResolver {
    /// Bounds every SwiftData `IN` query even when an MDBList contains thousands
    /// of ids. Sparse catalogs may inspect several batches to fill a preview,
    /// but only one bounded set of matching models is materialised at a time.
    nonisolated static let lookupBatchSize = 100

    static func snapshot(
        entries: [HomeListEntry],
        mediaType: HomeListEntry.MediaType?,
        context: SectionFeed.Context,
        previewLimit: Int
    ) async -> SectionCollectionSnapshot {
        let normalized = normalizedEntries(entries, mediaType: mediaType)
        let page = await page(entries: normalized, from: 0, limit: previewLimit, context: context)
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
    ) async -> SectionCollectionPage {
        let container = context.modelContext.container
        let request = SectionCollectionRequest(
            entries: entries,
            cursor: cursor,
            limit: limit,
            playlistPrefix: context.playlistPrefix,
            excludedCategoryIDs: context.restriction.excludedCategoryIDs
        )
        let resolutionTask = Task.detached(priority: .userInitiated) {
            SectionCollectionMatcher.page(container: container, request: request)
        }
        let resolution = await withTaskCancellationHandler {
            await resolutionTask.value
        } onCancel: {
            resolutionTask.cancel()
        }
        guard !Task.isCancelled else {
            let offset = min(max(cursor, 0), entries.count)
            return SectionCollectionPage(
                items: [],
                nextOffset: offset,
                hasMoreCandidates: offset < entries.count
            )
        }
        return SectionCollectionPage(
            items: resolution.matches.compactMap { match in
                switch match {
                case let .movie(id):
                    (context.modelContext.model(for: id) as? Movie).map(HomeMediaItem.movie)
                case let .series(id):
                    (context.modelContext.model(for: id) as? Series).map(HomeMediaItem.series)
                }
            },
            nextOffset: resolution.nextOffset,
            hasMoreCandidates: resolution.hasMoreCandidates
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
}

/// Performs the potentially long sparse-list scan on its own context. A custom
/// list with 1,800 entries can require every 100-id batch before finding 20
/// titles present in the user's catalog; doing those fetches on the view context
/// prevented Trakt rows and image completions from publishing until the scan
/// ended.
private nonisolated enum SectionCollectionMatcher {
    static func page(
        container: ModelContainer,
        request: SectionCollectionRequest
    ) -> SectionCollectionResolution {
        var offset = min(max(request.cursor, 0), request.entries.count)
        guard request.limit > 0, offset < request.entries.count else {
            return SectionCollectionResolution(matches: [], nextOffset: offset, hasMoreCandidates: false)
        }

        let context = ModelContext(container)
        var matches: [SectionCollectionMatch] = []
        while offset < request.entries.count, matches.count < request.limit, !Task.isCancelled {
            let upperBound = min(offset + SectionCollectionResolver.lookupBatchSize, request.entries.count)
            let batch = request.entries[offset ..< upperBound]
            let movies = fetchMovies(
                tmdbIds: batch.filter { $0.mediaType == .movie }.map(\.tmdbId),
                context: context,
                playlistPrefix: request.playlistPrefix,
                excludedCategoryIDs: request.excludedCategoryIDs
            )
            let series = fetchSeries(
                tmdbIds: batch.filter { $0.mediaType == .series }.map(\.tmdbId),
                context: context,
                playlistPrefix: request.playlistPrefix,
                excludedCategoryIDs: request.excludedCategoryIDs
            )

            while offset < upperBound, matches.count < request.limit {
                let entry = request.entries[offset]
                offset += 1
                switch entry.mediaType {
                case .movie:
                    if let id = movies[entry.tmdbId] { matches.append(.movie(id)) }
                case .series:
                    if let id = series[entry.tmdbId] { matches.append(.series(id)) }
                }
            }
        }

        return SectionCollectionResolution(
            matches: matches,
            nextOffset: offset,
            hasMoreCandidates: offset < request.entries.count
        )
    }

    private static func fetchMovies(
        tmdbIds: [Int],
        context: ModelContext,
        playlistPrefix: String?,
        excludedCategoryIDs: Set<String>
    ) -> [Int: PersistentIdentifier] {
        let ids = Set(tmdbIds)
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Movie>(predicate: movieTmdbIdPredicate(ids: ids))
        var byId: [Int: PersistentIdentifier] = [:]
        for movie in (try? context.fetch(descriptor)) ?? []
            where belongsToActivePlaylist(movie.id, prefix: playlistPrefix)
            && isVisible(movie.categoryId, excludedCategoryIDs: excludedCategoryIDs)
        {
            guard let tmdbId = movie.tmdbId, byId[tmdbId] == nil else { continue }
            byId[tmdbId] = movie.persistentModelID
        }
        return byId
    }

    private static func fetchSeries(
        tmdbIds: [Int],
        context: ModelContext,
        playlistPrefix: String?,
        excludedCategoryIDs: Set<String>
    ) -> [Int: PersistentIdentifier] {
        let ids = Set(tmdbIds)
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<Series>(predicate: seriesTmdbIdPredicate(ids: ids))
        var byId: [Int: PersistentIdentifier] = [:]
        for show in (try? context.fetch(descriptor)) ?? []
            where belongsToActivePlaylist(show.id, prefix: playlistPrefix)
            && isVisible(show.categoryId, excludedCategoryIDs: excludedCategoryIDs)
        {
            guard let tmdbId = show.tmdbId, byId[tmdbId] == nil else { continue }
            byId[tmdbId] = show.persistentModelID
        }
        return byId
    }

    private static func belongsToActivePlaylist(_ id: String, prefix: String?) -> Bool {
        guard let prefix else { return true }
        return id.hasPrefix(prefix)
    }

    private static func isVisible(_ categoryID: String?, excludedCategoryIDs: Set<String>) -> Bool {
        guard let categoryID else { return true }
        return !excludedCategoryIDs.contains(categoryID)
    }
}

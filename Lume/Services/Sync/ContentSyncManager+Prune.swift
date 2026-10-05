//
//  ContentSyncManager+Prune.swift
//  Lume
//
//  Prunes stale catalog content with a mark-and-sweep pass. The batched upsert
//  in every provider pipeline only ever inserts or updates the items a
//  fetch returns — it never removes items the provider has since dropped. Left
//  alone, a movie pulled from the provider's library, or a whole category that
//  no longer exists, lingers in the local store forever (storage bloat; the
//  indexer keeps resolving dead titles; browsing shows content that 404s on
//  playback).
//
//  Each sync accumulates the set of ids the provider returned for a content
//  kind ("seen") as it writes the batches, then sweeps the playlist's local rows
//  of that kind, deleting any id not in the set. Episodes cascade from their
//  `Series`; cast cascades from its parent — same cascade `PlaylistDeletion`
//  relies on.
//
//  SAFETY: a sweep against an empty/partial fetch would wipe the playlist's
//  catalog, so the `pruneStale*` sweeps are never called directly by a sync —
//  the guarded entry points below are, and they add the coverage gate a row
//  count alone cannot: `XtreamList` drops the elements that fail to decode and
//  only rethrows when *every* element fails, and a truncated m3u download
//  parses cleanly into a short but valid playlist. Either arrives as a small
//  non-empty payload that would wave the sweep through (see `allowSweep`).
//  Every pipeline — Xtream, m3u/WebDAV, Stalker, Jellyfin/Emby and Plex —
//  prunes through those entry points; `pruneStale*` stay visible only for the
//  tests and benchmarks that drive a sweep directly.
//  Pruning is confined to the local-only catalog store, so a delete never
//  propagates to CloudKit; and user state (favorites, progress, watchlist)
//  lives in `UserContentState` in the cloud mirror keyed by `contentId`, so it
//  survives a prune and is re-applied if the content ever returns (a missing
//  or blank catalog row is never read as the viewer clearing its state — see
//  `ContentIntentMerge`).
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    // MARK: - Xtream sweep entry points

    // These wrap the per-kind sweep with the non-empty-fetch guard and the
    // coverage check, so the batch-sync functions stay a single call. A working
    // Xtream provider never returns zero of a kind, so an empty fetch is a
    // transient failure — skipping the sweep then keeps the library.
    //
    // `seenIds` is accumulated by the caller's batch loop rather than derived
    // from the DTO array here: holding the decoded payload alive across the
    // sweep is what put the content phases in jetsam range on an Apple TV.
    // `fetchedCount` carries the payload's row count, which the array no longer
    // can once it has been released.

    func pruneMovies(playlistId: UUID, seenIds: Set<String>, fetchedCount: Int) {
        guard fetchedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "movie", seenCount: seenIds.count, storedMatching: scope) else {
            return
        }
        pruneStaleMovies(playlistId: playlistId, seenIds: seenIds)
    }

    func pruneSeries(playlistId: UUID, seenIds: Set<String>, fetchedCount: Int) {
        guard fetchedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "series", seenCount: seenIds.count, storedMatching: scope) else {
            return
        }
        pruneStaleSeries(playlistId: playlistId, seenIds: seenIds)
    }

    func pruneLiveStreams(playlistId: UUID, seenIds: Set<String>, fetchedCount: Int) {
        guard fetchedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "live", seenCount: seenIds.count, storedMatching: scope) else {
            return
        }
        pruneStaleLiveStreams(playlistId: playlistId, seenIds: seenIds)
    }

    // MARK: - Per-kind sweeps

    /// Deletes movies for `playlistId` whose id is absent from `seenIds`.
    func pruneStaleMovies(playlistId: UUID, seenIds: Set<String>) {
        sweepMovies(prefix: playlistId.uuidString) { seenIds.contains($0) }
    }

    /// Deletes series for `playlistId` whose id is absent from `seenIds`. Each
    /// removed series' episodes and cast cascade from the series — which is why
    /// the sweep deletes row by row instead of `delete(model:where:)`, whose
    /// bulk delete would leave those children (and the watch progress on them)
    /// orphaned.
    func pruneStaleSeries(playlistId: UUID, seenIds: Set<String>) {
        sweepSeries(prefix: playlistId.uuidString) { seenIds.contains($0) }
    }

    /// Deletes live streams for `playlistId` whose id is absent from `seenIds`.
    func pruneStaleLiveStreams(playlistId: UUID, seenIds: Set<String>) {
        sweepLiveStreams(prefix: playlistId.uuidString) { seenIds.contains($0) }
    }

    // MARK: - m3u sweep entry points

    // Same sweeps, membership tested against `M3UIdentity.hash64` of the id
    // instead of the id itself. A provider m3u file carries ~1.5M episode ids of
    // ~78 characters each — past Swift's inline small-string form, so every one
    // is a separate heap allocation — and the sets stay live across the whole
    // import and every sweep: ~337 MB resident against ~19-33 MB for the hashes.
    //
    // A 64-bit hash collides with probability ~6e-8 at 1.5M keys, and the
    // direction is benign: a collision makes a stale row test as seen, so the
    // sweep KEEPS it. It can never delete a row the file still carries.

    func pruneStaleM3UMovies(playlistId: UUID, seenHashes: Set<UInt64>) {
        sweepMovies(prefix: playlistId.uuidString) { seenHashes.contains(M3UIdentity.hash64($0)) }
    }

    func pruneStaleM3USeries(playlistId: UUID, seenHashes: Set<UInt64>) {
        sweepSeries(prefix: playlistId.uuidString) { seenHashes.contains(M3UIdentity.hash64($0)) }
    }

    func pruneStaleM3ULiveStreams(playlistId: UUID, seenHashes: Set<UInt64>) {
        sweepLiveStreams(prefix: playlistId.uuidString) { seenHashes.contains(M3UIdentity.hash64($0)) }
    }

    func pruneStaleM3UEpisodes(playlistId: UUID, seenHashes: Set<UInt64>) {
        sweepEpisodes(prefix: playlistId.uuidString) { seenHashes.contains(M3UIdentity.hash64($0)) }
    }

    // MARK: - m3u guarded sweep entry points

    // The m3u file is one uninterrupted `Transfer-Encoding: chunked` response
    // with no `Content-Length`, so a connection cut mid-download leaves a
    // *valid* short playlist: the parse succeeds, the import commits, and the
    // rows the truncated tail never mentioned look dropped. Sweeping on that
    // deletes them — the viewer's catalog shrinks (their `UserContentState`
    // survives in iCloud: the reconcile never reads a missing row as the user
    // clearing its state, see `ContentIntentMerge`). So the m3u sweeps take
    // the same gate as the Xtream ones: a payload must cover at least a tenth
    // of the rows already stored; CatalogSweepPolicy holds twice before a
    // repeated shrink is believed. Unreadable storage never grants a sweep.
    //
    // Deliberate behaviour change: a provider that genuinely drops a whole
    // section now keeps those dead rows for up to two extra syncs.
    //
    // `importedCount` is the import's TOTAL row count, not the kind's — a
    // live-only playlist imports zero movies and must still prune the movies it
    // used to carry, while a zero total means the download or parse produced
    // nothing at all.
    //
    // The coverage floor counts the seen set against the playlist-scoped stored
    // rows, so it reads the same whether the set holds ids or their hashes.

    func pruneLiveStreams(playlistId: UUID, seenHashes: Set<UInt64>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "live", seenCount: seenHashes.count, storedMatching: scope) else {
            return
        }
        pruneStaleM3ULiveStreams(playlistId: playlistId, seenHashes: seenHashes)
    }

    func pruneMovies(playlistId: UUID, seenHashes: Set<UInt64>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "movie", seenCount: seenHashes.count, storedMatching: scope) else {
            return
        }
        pruneStaleM3UMovies(playlistId: playlistId, seenHashes: seenHashes)
    }

    func pruneEpisodes(playlistId: UUID, seenHashes: Set<UInt64>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Episode>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "episode", seenCount: seenHashes.count, storedMatching: scope) else {
            return
        }
        pruneStaleM3UEpisodes(playlistId: playlistId, seenHashes: seenHashes)
    }

    func pruneSeries(playlistId: UUID, seenHashes: Set<UInt64>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = playlistId.uuidString
        let scope = FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "series", seenCount: seenHashes.count, storedMatching: scope) else {
            return
        }
        pruneStaleM3USeries(playlistId: playlistId, seenHashes: seenHashes)
    }

    /// Guarded `pruneStaleCategories`, shared by every pipeline. Scoped per
    /// type, and so is the skip count: the m3u file's three types are
    /// accumulated from one file but a truncation starves them independently,
    /// and every other source lists each type with its own request.
    /// `importedCount` is whatever the caller's "nothing came back at all"
    /// signal is — the m3u import's total, or a category list's own length.
    func pruneCategories(playlistId: UUID, type: CategoryType, seenApiIds: Set<String>, importedCount: Int) {
        guard importedCount > 0 else { return }
        let prefix = CatalogID.prefix(playlistId, infix: type.rawValue)
        let scope = FetchDescriptor<Category>(predicate: #Predicate { $0.id.starts(with: prefix) })
        guard sweepIsAllowed(
            playlistId: playlistId,
            kind: "category.\(type.rawValue)",
            seenCount: seenApiIds.count,
            storedMatching: scope
        ) else {
            return
        }
        pruneStaleCategories(playlistId: playlistId, type: type, seenApiIds: seenApiIds)
    }

    // MARK: - Media-server guarded sweep entry points

    // Jellyfin/Emby and Plex rows carry a source infix after the playlist UUID
    // (`"<playlist>-plex-…"`, `"<playlist>-jellyfin-…"`), so `idPrefix` names
    // exactly the rows the pipeline owns and the sweep never reads anything
    // else. Pages rather than one fetch of the playlist's whole catalog, and
    // takes the same coverage gate as every other sweep: a server that answers
    // one page of a library and then drops the connection mid-walk has not
    // shown the rest of it to be gone.
    //
    // The caller's own guard is "the server listed at least one library of
    // this kind" — an empty library list is the transient-failure signature.
    // An empty *library* is not, and still reaches the coverage gate.

    func pruneMovies(playlistId: UUID, idPrefix: String, seenIds: Set<String>) {
        let scope = FetchDescriptor<Movie>(predicate: #Predicate { $0.id.starts(with: idPrefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "movie", seenCount: seenIds.count, storedMatching: scope) else {
            return
        }
        sweepMovies(prefix: idPrefix) { seenIds.contains($0) }
    }

    /// Unseen series go first, taking their episodes and cast with them by
    /// cascade; `pruneEpisodes` then collects what a surviving show dropped.
    func pruneSeries(playlistId: UUID, idPrefix: String, seenIds: Set<String>) {
        let scope = FetchDescriptor<Series>(predicate: #Predicate { $0.id.starts(with: idPrefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "series", seenCount: seenIds.count, storedMatching: scope) else {
            return
        }
        sweepSeries(prefix: idPrefix) { seenIds.contains($0) }
    }

    /// Episodes are swept on their own id range rather than by walking each
    /// surviving series' `episodes`, which faulted every show's whole episode
    /// list into memory at once.
    func pruneEpisodes(playlistId: UUID, idPrefix: String, seenIds: Set<String>) {
        let scope = FetchDescriptor<Episode>(predicate: #Predicate { $0.id.starts(with: idPrefix) })
        guard sweepIsAllowed(playlistId: playlistId, kind: "episode", seenCount: seenIds.count, storedMatching: scope) else {
            return
        }
        sweepEpisodes(prefix: idPrefix) { seenIds.contains($0) }
    }

    // MARK: - Shared sweep bodies

    // `prefix` is the playlist UUID, or a longer prefix under it for a source
    // that owns only part of the id range. The UUID anchors every id this
    // playlist produced (see PlaylistDeletion). `starts(with:)` compiles to a
    // range seek on the unique `id` index; the substring match used before was
    // a LIKE-%…% scan that touched every row on each sync's sweep.

    private func sweepMovies(prefix: String, isSeen: (String) -> Bool) {
        let removed = sweepPaged(after: prefix, isSeen: isSeen, idOf: { (movie: Movie) in movie.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<Movie>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id, comparator: .lexical)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
        guard removed > 0 else { return }
        Logger.database.info("Pruned \(removed) stale movie(s) for playlist \(prefix)")
    }

    private func sweepSeries(prefix: String, isSeen: (String) -> Bool) {
        let removed = sweepPaged(after: prefix, isSeen: isSeen, idOf: { (show: Series) in show.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<Series>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id, comparator: .lexical)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
        guard removed > 0 else { return }
        Logger.database.info("Pruned \(removed) stale series for playlist \(prefix)")
    }

    private func sweepLiveStreams(prefix: String, isSeen: (String) -> Bool) {
        let removed = sweepPaged(after: prefix, isSeen: isSeen, idOf: { (stream: LiveStream) in stream.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<LiveStream>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id, comparator: .lexical)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
        guard removed > 0 else { return }
        Logger.database.info("Pruned \(removed) stale live stream(s) for playlist \(prefix)")
    }

    private func sweepEpisodes(prefix: String, isSeen: (String) -> Bool) {
        // Episode.id is "\(seriesId)-episode-…" and seriesId starts with the
        // playlist UUID, so the same prefix scope applies.
        let removed = sweepPaged(after: prefix, isSeen: isSeen, idOf: { (episode: Episode) in episode.id }, page: { cursor, limit in
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.id.starts(with: prefix) && $0.id > cursor },
                sortBy: [SortDescriptor(\.id, comparator: .lexical)]
            )
            descriptor.fetchLimit = limit
            return descriptor
        })
        guard removed > 0 else { return }
        Logger.database.info("Pruned \(removed) stale episode(s) for playlist \(prefix)")
    }

    /// Deletes categories of `type` for `playlistId` whose `apiId` is absent
    /// from `seenApiIds`. Scoped per type — VOD / series / live categories sync
    /// from separate provider calls, so a `seenApiIds` set for one type must not
    /// reach another type's rows.
    func pruneStaleCategories(playlistId: UUID, type: CategoryType, seenApiIds: Set<String>) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        // Match fetchCategoryLookup: the "<playlist>-<type>-" prefix
        // scopes to this playlist and type in one index seek.
        let prefix = CatalogID.prefix(playlistId, infix: type.rawValue)
        let typeRaw = type.rawValue
        let descriptor = FetchDescriptor<Category>(
            predicate: #Predicate { $0.id.starts(with: prefix) }
        )
        var removed = 0
        for category in (try? context.fetch(descriptor)) ?? [] where !seenApiIds.contains(category.apiId) {
            context.delete(category)
            removed += 1
        }
        guard removed > 0 else { return }
        try? context.save()
        Logger.database.info("Pruned \(removed) stale \(typeRaw) category/ies for playlist \(prefix)")
    }

    // MARK: - Paged sweep

    /// Deletes the rows `page` returns that `seenIds` doesn't cover, one page at
    /// a time, and answers how many went.
    ///
    /// Paging is what keeps the sweep off the heap: fetching a playlist's whole
    /// catalog materialised every row as a managed object — 178k VOD rows cost
    /// ~1.2 GB peak even when nothing was deleted. Each page runs on its own
    /// `ModelContext` inside an `autoreleasepool`, so a page's objects are gone
    /// before the next one is read.
    ///
    /// Pages are keyed on the last id seen, never on `fetchOffset`: an offset
    /// makes the store walk the rows it is skipping, which turned the same sweep
    /// into ~99 s of index scanning (against 9 s for the single unbounded
    /// fetch). Seeking on `id` instead is also what makes deleting while paging
    /// sound — every row a page removes sorts at or before the cursor, so it
    /// cannot displace a row the next page has yet to see. `page` must therefore
    /// ask for `id > cursor` ordered by `id` with `comparator: .lexical`: the
    /// default String comparator is Finder-style and number-aware ("-9" before
    /// "-10"), while `id > cursor` compares bytes, so with the default the two
    /// orders disagree and every page skips the ids whose digit count changes —
    /// a real 180,971-row Xtream VOD catalog swept only 31,951 of them. The
    /// lexical order is also the one the unique `id` index already holds, so
    /// each page is a range seek instead of a sort. `after` must be a string that
    /// sorts before every id in scope (the playlist prefix does: a prefix sorts
    /// before anything extending it). The cursor strictly increases each pass
    /// and a short page means the rows ran out, so the loop terminates. The
    /// callers pass their scoping prefix as `after`.
    ///
    /// Membership is a closure rather than a `Set<String>` so a caller can hold
    /// its seen ids in a cheaper form: the m3u pipeline keeps 64-bit hashes
    /// instead of the ids themselves (see `pruneStaleM3U*`).
    private func sweepPaged<T: PersistentModel>(
        after: String,
        isSeen: (String) -> Bool,
        idOf: (T) -> String,
        pageSize: Int = 2000,
        page: (_ cursor: String, _ limit: Int) -> FetchDescriptor<T>
    ) -> Int {
        var cursor = after
        var totalRemoved = 0

        while true {
            var fetched = 0
            var removed = 0

            autoreleasepool {
                let context = ModelContext(modelContainer)
                context.autosaveEnabled = false

                let rows = (try? context.fetch(page(cursor, pageSize))) ?? []
                fetched = rows.count
                if let last = rows.last { cursor = idOf(last) }

                for row in rows where !isSeen(idOf(row)) {
                    context.delete(row)
                    removed += 1
                }
                if removed > 0 { try? context.save() }
            }

            totalRemoved += removed
            if fetched < pageSize { break }
        }

        return totalRemoved
    }

    /// Whether a provider payload may drive a sweep of `kind`, applying
    /// `CatalogSweepPolicy` against the rows already stored and the skips
    /// persisted for this playlist and kind.
    ///
    /// `XtreamList` drops elements that fail to decode and rethrows only when
    /// *every* element fails, so a payload whose rows are mostly malformed
    /// arrives as a small non-empty array that the callers' `isEmpty` guards let
    /// through — and sweeping against it would delete nearly the whole catalog
    /// along with the enrichment and ordering on those rows. A failed count is
    /// distinct from low coverage: it holds the digest open for retry, but can
    /// never authorize pruning by exhausting skips. Counting is an aggregate
    /// query, so it costs no materialised rows.
    private func sweepIsAllowed(
        playlistId: UUID,
        kind: String,
        seenCount: Int,
        storedMatching descriptor: FetchDescriptor<some PersistentModel>
    ) -> Bool {
        let context = ModelContext(modelContainer)
        let stored = try? context.fetchCount(descriptor)
        let key = SweepSkipDefaults.key(playlistId: playlistId, kind: kind)
        let defaults = UserDefaults.standard
        let previous = defaults.integer(forKey: key)
        switch CatalogSweepPolicy.decide(seenCount: seenCount, storedCount: stored, previousSkips: previous) {
        case .sweep:
            clearSweepSkips(playlistId: playlistId, kind: kind)
            return true
        case .unreadable:
            // Keep a marker so an unchanged digest cannot skip unfinished work.
            defaults.set(previous, forKey: key)
            Logger.database.warning("Skipped \(kind, privacy: .public) prune for playlist \(playlistId.uuidString, privacy: .public): stored count unreadable")
            return false
        case let .hold(skips):
            defaults.set(skips, forKey: key)
            Logger.database.warning(
                "Skipped \(kind, privacy: .public) prune for playlist \(playlistId.uuidString, privacy: .public): payload covers too few stored rows (\(skips, privacy: .public) in a row)"
            )
            return false
        case let .acceptShrink(skips):
            Logger.database.warning(
                "Sweeping \(kind, privacy: .public) for playlist \(playlistId.uuidString, privacy: .public) after \(skips, privacy: .public) low-coverage payloads: treating the shrink as real"
            )
            clearSweepSkips(playlistId: playlistId, kind: kind)
            return true
        }
    }

    private func clearSweepSkips(playlistId: UUID, kind: String) {
        UserDefaults.standard.removeObject(forKey: SweepSkipDefaults.key(playlistId: playlistId, kind: kind))
    }
}

/// Where `sweepIsAllowed` keeps its consecutive-skip counters.
///
/// Device-local by design: the counter describes what this device's downloads
/// looked like, and mirroring it would let one device's bad payload suppress
/// another's sweep. That makes them invisible to the playlist's own deletion
/// cascade, so the layout is spelled out here for `PlaylistDeletion` to clear —
/// otherwise every deleted playlist leaks a key per content kind.
nonisolated enum SweepSkipDefaults {
    static func key(playlistId: UUID, kind: String) -> String {
        "\(keyPrefix(playlistId: playlistId))\(kind)"
    }

    /// Whether any sweep for this playlist is currently being held back. The m3u
    /// digest skip reads it: a deferred sweep is unfinished work, and recording
    /// the file as fully imported would strand those rows until the provider
    /// changed the file.
    static func hasAny(playlistId: UUID) -> Bool {
        let prefix = keyPrefix(playlistId: playlistId)
        return UserDefaults.standard.dictionaryRepresentation().keys.contains { $0.hasPrefix(prefix) }
    }

    /// Whether the sweep of one content kind is currently being held back. The
    /// Xtream digest skip reads it per kind, since each endpoint is its own
    /// payload.
    static func isHoldingBack(playlistId: UUID, kind: String) -> Bool {
        UserDefaults.standard.object(forKey: key(playlistId: playlistId, kind: kind)) != nil
    }

    static func removeAll(playlistId: UUID) {
        let prefix = keyPrefix(playlistId: playlistId)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func keyPrefix(playlistId: UUID) -> String {
        "sync.sweepSkips.\(playlistId.uuidString)."
    }
}

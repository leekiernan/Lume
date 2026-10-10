import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    func syncMovies(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil, reuseUnchanged: Bool = false) async throws {
        let prefix = CatalogID.prefix(playlistId, infix: CategoryType.vod.rawValue)
        try await runXtreamContentPhase(.movies, playlistId: playlistId, progress: progress, reuseUnchanged: reuseUnchanged,
                                        fetch: { known in try await xtreamRequest {
                                            try await $0.getVODStreamsIfChanged(playlist: playlist, knownDigest: known?.digest, knownValidator: known?.validator)
                                        } },
                                        upsert: { batch, context in
                                            try CatalogUpsert.batch(batch, context: context,
                                                                    identity: { $0.streamId.map { CatalogID.content(playlistId, kind: .movie, key: $0) } },
                                                                    create: { Movie(id: $1, streamId: $0.streamId ?? 0, name: "") },
                                                                    apply: { applyMovieFields(from: $0, to: $1, playlistPrefix: prefix) })
                                        })
    }

    func syncSeries(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil, reuseUnchanged: Bool = false) async throws {
        let prefix = CatalogID.prefix(playlistId, infix: CategoryType.series.rawValue)
        try await runXtreamContentPhase(.series, playlistId: playlistId, progress: progress, reuseUnchanged: reuseUnchanged,
                                        fetch: { known in try await xtreamRequest {
                                            try await $0.getSeriesIfChanged(playlist: playlist, knownDigest: known?.digest, knownValidator: known?.validator)
                                        } },
                                        upsert: { batch, context in
                                            try CatalogUpsert.batch(batch, context: context,
                                                                    identity: { $0.seriesId.map { CatalogID.content(playlistId, kind: .series, key: $0) } },
                                                                    create: { Series(id: $1, seriesId: $0.seriesId ?? 0, name: "") },
                                                                    apply: { applySeriesFields(from: $0, to: $1, playlistPrefix: prefix) })
                                        })
    }

    func syncLiveStreams(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil, reuseUnchanged: Bool = false) async throws {
        let prefix = CatalogID.prefix(playlistId, infix: CategoryType.live.rawValue)
        try await runXtreamContentPhase(.live, playlistId: playlistId, progress: progress, reuseUnchanged: reuseUnchanged,
                                        fetch: { known in try await xtreamRequest {
                                            try await $0.getLiveStreamsIfChanged(playlist: playlist, knownDigest: known?.digest, knownValidator: known?.validator)
                                        } },
                                        upsert: { batch, context in
                                            try CatalogUpsert.batch(batch, context: context,
                                                                    identity: { $0.streamId.map { CatalogID.content(playlistId, kind: .live, key: $0) } },
                                                                    create: { LiveStream(id: $1, streamId: $0.streamId ?? 0, name: "") },
                                                                    apply: { applyLiveStreamFields(from: $0, to: $1, playlistPrefix: prefix) })
                                        })
    }

    /// Only the phase envelope is shared. Mapping and guarded sweeps stay
    /// kind-specific. Each batch has a fresh context and autorelease pool;
    /// neither that context nor its models survives across an async boundary.
    func runXtreamContentPhase<Element: Sendable>( // swiftlint:disable:this function_parameter_count
        _ endpoint: XtreamDigestStore.Endpoint, playlistId: UUID,
        progress: SyncProgress?, reuseUnchanged: Bool,
        fetch: (XtreamDigestStore.Entry?) async throws -> XtreamFetch<[Element]>,
        upsert: (ArraySlice<Element>, ModelContext) throws -> [String]
    ) async throws {
        let interval = Perf.begin(endpoint.syncSignpost)
        defer { Perf.end(interval) }
        guard case .fetched(var items, let digest, let validator) = try await beginXtreamPhase(
            endpoint, playlistId: playlistId, reuseUnchanged: reuseUnchanged, progress: progress, fetch: fetch
        ) else { return }
        let count = items.count
        var seen = Set<String>(minimumCapacity: count)
        do {
            let interval = Perf.begin(endpoint.upsertSignpost)
            defer { Perf.end(interval) }
            for start in stride(from: 0, to: count, by: batchSize) {
                try Task.checkCancellation()
                let end = min(start + batchSize, count)
                try autoreleasepool {
                    let context = ModelContext(modelContainer)
                    context.autosaveEnabled = false
                    try seen.formUnion(upsert(items[start ..< end], context))
                    if context.hasChanges { try context.save() }
                    Logger.database.info("Synced \(endpoint.label) \(start + 1)–\(end) of \(count)")
                }
                await progress?.update(detail: "\(end) of \(count)", fraction: Double(end) / Double(count))
            }
        }
        // Release the decoded catalog before the sweep allocates its own pages.
        items = []
        // Cancellation after the final batch must not certify a digest.
        try Task.checkCancellation()
        await finishXtreamPhase(endpoint, payload: (digest, count, seen.count, validator), playlistId: playlistId, progress: progress) {
            switch endpoint {
            case .movies: pruneMovies(playlistId: playlistId, seenIds: seen, fetchedCount: count)
            case .series: pruneSeries(playlistId: playlistId, seenIds: seen, fetchedCount: count)
            case .live: pruneLiveStreams(playlistId: playlistId, seenIds: seen, fetchedCount: count)
            }
        }
    }
}

nonisolated extension XtreamDigestStore.Endpoint {
    var syncSignpost: PerfSignpost {
        switch self {
        case .movies: .syncMovies
        case .series: .syncSeries
        case .live: .syncLiveStreams
        }
    }

    var upsertSignpost: PerfSignpost {
        switch self {
        case .movies: .upsertMovies
        case .series: .upsertSeries
        case .live: .upsertLiveStreams
        }
    }
}

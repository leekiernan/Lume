//
//  ContentSyncManager.swift
//  Lume
//
//  Manages content synchronization from Xtream API to SwiftData
//

import Foundation
import OSLog
import SwiftData

private struct ProviderSyncRequest {
    let playlistID: UUID
    let progress: SyncProgress?
    let full: Bool
    let repairingAreas: Set<AppArea>?
    let syncAreas: Set<AppArea>?
}

// MARK: - ContentSyncManager

actor ContentSyncManager {
    // MARK: - Properties

    let modelContainer: ModelContainer
    let xtreamClient: XtreamClient
    let webdavClient: WebDAVClient
    let jellyfinClient: JellyfinClient
    let plexClient: PlexClient
    private var activeSyncPlaylistIDs: Set<UUID> = []

    /// When the most recent Xtream request returned, on a monotonic clock.
    /// Stamped by `xtreamRequest(_:)`; read by `spaceContentPhaseRequests()`.
    var lastXtreamRequestFinishedAt: ContinuousClock.Instant?

    /// Number of items to process before saving and resetting the context.
    let batchSize = 2000

    // MARK: - Initialization

    init(
        modelContainer: ModelContainer,
        xtreamClient: XtreamClient = XtreamClient(),
        webdavClient: WebDAVClient = WebDAVClient(),
        jellyfinClient: JellyfinClient = JellyfinClient(),
        plexClient: PlexClient = PlexClient()
    ) {
        self.modelContainer = modelContainer
        self.xtreamClient = xtreamClient
        self.webdavClient = webdavClient
        self.jellyfinClient = jellyfinClient
        self.plexClient = plexClient
    }

    // MARK: - Playlist Sync

    /// Performs a full sync of a playlist (categories and content)
    func syncPlaylist(
        _ playlist: Playlist,
        progress: SyncProgress? = nil,
        full: Bool = false,
        repairingAreas: Set<AppArea>? = nil,
        syncAreas: Set<AppArea>? = nil
    ) async throws {
        let playlistId = playlist.id

        guard !activeSyncPlaylistIDs.contains(playlistId) else {
            throw SyncError.syncInProgress
        }

        activeSyncPlaylistIDs.insert(playlistId)
        defer { activeSyncPlaylistIDs.remove(playlistId) }

        do {
            // Run directly in the caller's task — no wrapping unstructured Task —
            // so cancelling the caller (e.g. the user aborting from the progress
            // sheet) propagates here and tears the sync down.
            try await performSync(
                playlistId: playlistId,
                progress: progress,
                full: full,
                repairingAreas: repairingAreas,
                syncAreas: syncAreas
            )
        } catch {
            // An aborted sync isn't a failure: restore the playlist to idle so it
            // can be retried cleanly, rather than wedging it in the error state.
            if Task.isCancelled {
                Logger.database.info("Sync cancelled for playlist \(playlistId)")
                markPlaylistIdle(playlistId: playlistId)
            } else {
                Logger.database.error("Sync failed for playlist \(playlistId) — \(error)")
                markPlaylistError(playlistId: playlistId)
            }
            throw error
        }

        Logger.database.info("Completed sync for playlist \(playlistId)")

        // Nudge iCloud sync: a freshly fetched catalog may now be able to apply
        // cloud user state (favorites / progress) that was waiting for it.
        NotificationCenter.default.post(name: .lumeContentSyncDidComplete, object: nil)
    }

    private func performSync(
        playlistId: UUID,
        progress: SyncProgress?,
        full: Bool,
        repairingAreas: Set<AppArea>?,
        syncAreas: Set<AppArea>?
    ) async throws {
        // Whole-sync interval: the umbrella every phase below nests under, so a
        // trace (or `XCTOSSignpostMetric`) shows both the total and the split.
        let interval = Perf.begin(.playlistSync)
        defer { Perf.end(interval) }

        let statusContext = ModelContext(modelContainer)
        statusContext.autosaveEnabled = false
        guard let playlist = try statusContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else {
            Logger.database.error("Sync aborted: playlist \(playlistId) not found in store")
            throw SyncError.playlistNotFound
        }

        playlist.syncStatus = .syncing
        try statusContext.save()

        let request = ProviderSyncRequest(
            playlistID: playlistId,
            progress: progress,
            full: full,
            repairingAreas: repairingAreas,
            syncAreas: syncAreas
        )
        let syncedAreas = try await runProviderSync(for: playlist, request: request)

        // Every source writes the same unread history rows (see the method).
        purgeCatalogHistory()

        let doneContext = ModelContext(modelContainer)
        doneContext.autosaveEnabled = false
        if let dpl = try doneContext.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first {
            dpl.syncStatus = .idle
            if repairingAreas == nil { dpl.lastSyncDate = Date() }
            try doneContext.save()
        }
        // A failed/cancelled run leaves prior coverage intact so its retry is not suppressed.
        PlaylistSyncCoverage.record(syncedAreas, playlistID: playlistId)
    }

    /// Runs the pipeline for `playlist`'s source type, returning the content
    /// areas the run covered — see `PlaylistSyncCoverage`. Every pipeline syncs
    /// only `syncAreas` (the Library toggles, narrowed by a repair); Xtream
    /// reports the phases it actually ran, the others the areas they were
    /// handed, and each adds the areas its source cannot supply at all.
    private func runProviderSync(
        for playlist: Playlist,
        request: ProviderSyncRequest
    ) async throws -> Set<AppArea> {
        let sourceType = playlist.sourceType
        let requestedAreas = request.syncAreas ?? Self.syncAreas(
            enabled: AppAreaSettings.enabledContentAreas(disabledRaw: AppAreaSettings.storedValue),
            repairing: request.repairingAreas
        )
        let areas = requestedAreas.subtracting(Self.unsupportedAreas(for: sourceType))
        guard !areas.isEmpty else {
            Logger.database.info("Skipping playlist sync: active profile has no supported catalog areas")
            return Self.unsupportedAreas(for: sourceType)
        }
        var synced = areas
        switch sourceType {
        case .xtream:
            synced = try await performXtreamSync(
                playlist: playlist, playlistId: request.playlistID, progress: request.progress, areas: areas, full: request.full
            )
        case .m3u:
            try await performM3USync(playlist: playlist, playlistId: request.playlistID, progress: request.progress, areas: areas)
        case .stalker:
            try await performStalkerSync(
                playlist: playlist, playlistId: request.playlistID, progress: request.progress, full: request.full, areas: areas
            )
        case .webdav:
            try await performWebDAVSync(playlist: playlist, playlistId: request.playlistID, progress: request.progress, areas: areas)
        case .jellyfin, .emby:
            // Both speak the same API; the flavour only tags the rows.
            let flavor = MediaServerFlavor(sourceType: sourceType) ?? .jellyfin
            try await performMediaServerSync(
                playlist: playlist, playlistId: request.playlistID, flavor: flavor, progress: request.progress, areas: areas
            )
        case .plex:
            try await performPlexSync(playlist: playlist, playlistId: request.playlistID, progress: request.progress, areas: areas)
        }
        return synced.union(Self.unsupportedAreas(for: sourceType))
    }

    // MARK: - Category Sync

    func syncVODCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        let categories = try await xtreamRequest { try await $0.getVODCategories(playlist: playlist) }
        Logger.database.info("Fetched \(categories.count) VOD categories")
        await progress?.update(detail: "\(categories.count) categories")
        try syncCategories(categories, type: .vod, playlistId: playlistId)
    }

    func syncSeriesCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        let categories = try await xtreamRequest { try await $0.getSeriesCategories(playlist: playlist) }
        Logger.database.info("Fetched \(categories.count) Series categories")
        await progress?.update(detail: "\(categories.count) categories")
        try syncCategories(categories, type: .series, playlistId: playlistId)
    }

    func syncLiveCategories(for playlist: Playlist, playlistId: UUID, progress: SyncProgress? = nil) async throws {
        let categories = try await xtreamRequest { try await $0.getLiveCategories(playlist: playlist) }
        Logger.database.info("Fetched \(categories.count) Live categories")
        await progress?.update(detail: "\(categories.count) categories")
        try syncCategories(categories, type: .live, playlistId: playlistId)
    }

    private func syncCategories(_ dtos: [XtreamCategory], type: CategoryType, playlistId: UUID) throws {
        let interval = Perf.begin(.syncCategories)
        defer { Perf.end(interval) }
        try syncProviderCategories(dtos.map {
            ProviderCategory(id: $0.categoryId, name: $0.categoryName, parentID: $0.parentId ?? 0)
        }, type: type, playlistId: playlistId)
    }

    /// Syncs episodes for a series
    /// Fetches and parses a series' episodes from the provider **without**
    /// touching the database.
    ///
    /// The caller inserts the returned episodes through its own (view) context,
    /// attaching them to the `Series` instance it already holds. Writing through
    /// a separate background context instead leaves the view-context series'
    /// `episodes` relationship stale until a later cross-context merge — which
    /// races the UI refresh and, on tvOS, loses (episodes only appear after
    /// navigating away and back). Returning value types sidesteps that entirely.
    func fetchEpisodes(seriesId: Int, seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        switch playlist.sourceType {
        case .xtream:
            try await fetchXtreamEpisodes(seriesId: seriesId, seriesElementId: seriesElementId, playlist: playlist)
        case .stalker:
            try await fetchStalkerEpisodes(seriesId: seriesId, seriesElementId: seriesElementId, playlist: playlist)
        case .m3u:
            // m3u episodes are imported alongside the rest of the catalog during
            // sync, so there is nothing to fetch lazily here.
            []
        case .webdav:
            // WebDAV episodes are imported alongside the rest of the catalog
            // during sync, so there is nothing to fetch lazily here.
            []
        case .jellyfin, .emby, .plex:
            // Media-server episodes are imported alongside the rest of the
            // catalog during sync, so there is nothing to fetch lazily here.
            []
        }
    }

    private func fetchXtreamEpisodes(seriesId: Int, seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        let seriesInfo = try await xtreamRequest { try await $0.getSeriesInfo(playlist: playlist, seriesId: seriesId) }
        guard let episodesDict = seriesInfo.episodes else { return [] }

        var result: [ParsedEpisode] = []
        for (seasonKey, episodes) in episodesDict {
            guard let seasonNum = Int(seasonKey) else { continue }
            for episodeDTO in episodes {
                guard let episodeIdString = episodeDTO.id else { continue }
                let plot = episodeDTO.info?.plot
                result.append(ParsedEpisode(
                    id: "\(seriesElementId)-episode-\(episodeIdString)",
                    episodeId: episodeIdString,
                    title: Self.cleanEpisodeTitle(episodeDTO.title),
                    containerExtension: episodeDTO.containerExtension ?? "mkv",
                    seasonNum: seasonNum,
                    episodeNum: episodeDTO.episodeNum ?? 0,
                    added: episodeDTO.added,
                    directSource: episodeDTO.directSource,
                    durationSecs: episodeDTO.info?.durationSecs,
                    movieImage: episodeDTO.info?.movieImage,
                    rating: episodeDTO.info?.rating,
                    airDate: episodeDTO.info?.airDate,
                    plot: (plot?.isEmpty == false) ? plot : nil
                ))
            }
        }
        return result
    }

    /// Reduces a raw Xtream episode title to just the episode name.
    ///
    /// Providers commonly prefix the series and a season/episode token, e.g.
    /// "Breaking Bad - S05E16 - Felina" or "Breaking Bad S05E16 Felina". We locate
    /// the first `SxxExx` / `NxM` token and keep whatever follows it ("Felina").
    /// Titles with no such token are returned untouched; a token with nothing after
    /// it (e.g. "Breaking Bad - S05E16") yields "" so the UI can fall back to "E16".
    static func cleanEpisodeTitle(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }

        let token = #"(?i)\bS\d{1,3}\s*E\d{1,4}\b|\b\d{1,3}x\d{1,4}\b"#
        guard let match = raw.range(of: token, options: .regularExpression) else {
            return raw
        }

        let separators = CharacterSet(charactersIn: " -–—·:|.").union(.whitespacesAndNewlines)
        return raw[match.upperBound...].trimmingCharacters(in: separators)
    }
}

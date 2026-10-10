//
//  ContentSyncManager+Episodes.swift
//  Lume
//
//  The lazily-fetched episode path for the Xtream / Stalker pipelines:
//  provider episodes parsed off the main actor, then materialized onto the
//  view context's series. Split out of ContentSyncManager.swift to keep that
//  file within the project's file-length limit.
//

import Foundation
import SwiftData

// MARK: - ParsedEpisode

/// A provider episode parsed off the main actor, ready to be turned into an
/// `Episode` model by the caller on its own context. Value type so it can cross
/// the actor boundary safely.
nonisolated struct ParsedEpisode {
    let id: String
    let episodeId: String
    let title: String
    /// Nil means the provider omitted it, not that an existing episode is MKV.
    let containerExtension: String?
    let seasonNum: Int
    let episodeNum: Int
    let added: String?
    let directSource: String?
    let durationSecs: Int?
    let movieImage: String?
    let rating: Double?
    let airDate: String?
    let plot: String?
}

/// Metadata and episodes travel together without carrying a context across the
/// fetch boundary. The owning view applies both before the episode-cache save.
nonisolated struct FetchedEpisodes {
    let episodes: [ParsedEpisode]
    var seriesInfo: XtreamSeriesInfo?
}

extension Series {
    func applyFetchedEpisodes(_ fetched: FetchedEpisodes, into context: ModelContext) {
        if let info = fetched.seriesInfo { applyProviderMetadata(info, fillMissing: true) }
        insertEpisodes(fetched.episodes, into: context)
    }

    /// Materializes fetched episodes on `context` and links them to this series,
    /// de-duping against any already present (Episode.id is unique). Mutating the
    /// `episodes` relationship directly updates any observing SwiftUI view, so the
    /// caller must run this on the same context the view renders from.
    ///
    /// Non-destructive on purpose: a refresh updates supplied metadata and merges
    /// in new episodes, but never deletes, so a provider hiccup (a short or
    /// empty `get_series_info` response) can't wipe rows that carry watch
    /// progress. Call only after a *successful* fetch — it stamps the episode
    /// cache, which suppresses further refreshes until it goes stale again.
    func insertEpisodes(_ parsed: [ParsedEpisode], into context: ModelContext) {
        var existing = episodes.reduce(into: [String: Episode]()) { $0[$1.id] = $1 }
        var inserted = false
        for parsed in parsed {
            if let episode = existing[parsed.id] {
                episode.applyProviderMetadata(parsed)
                continue
            }
            inserted = true
            let episode = Episode(
                id: parsed.id,
                episodeId: parsed.episodeId,
                title: parsed.title,
                containerExtension: parsed.containerExtension.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "mkv",
                seasonNum: parsed.seasonNum,
                episodeNum: parsed.episodeNum,
                added: parsed.added,
                directSource: parsed.directSource
            )
            episode.applyProviderMetadata(parsed)
            context.insert(episode)
            episodes.append(episode)
            existing[parsed.id] = episode
        }
        // A tracker import can only mark episodes that exist, so anything
        // parked for this series is applied here — the one place episodes ever
        // materialize for Xtream and Stalker.
        TraktWatchedImporter.applyPending(to: self)
        SimklWatchedImporter.applyPending(to: self)
        episodesFetchedAt = Date()
        episodesFetchedLastModified = lastModified
        try? context.save()
        // Watched state synced from another device (or kept in iCloud across a
        // reinstall) waits as pending until its episode exists. Without a pass
        // now, the page just opened showed those episodes unwatched until the
        // next launch.
        if inserted {
            NotificationCenter.default.post(name: .lumeEpisodesDidMaterialize, object: self)
        }
    }
}

extension Episode {
    /// Partial provider responses are patches, not deletions. Keep playback
    /// identity, downloads and watch/tracker state on the existing instance.
    /// Playback inputs are the provider's, though: a remux changes the
    /// container extension (Xtream builds the stream URL from it) and a
    /// Stalker `cmd` goes stale, so supplied values replace cached ones. A
    /// completed download keeps its own stored file path.
    func applyProviderMetadata(_ parsed: ParsedEpisode) {
        for (keyPath, value) in [(\Episode.containerExtension, parsed.containerExtension), (\Episode.title, Optional(parsed.title))] {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self[keyPath: keyPath] != value else { continue }
            self[keyPath: keyPath] = value
        }
        if let value = parsed.directSource, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, directSource != value { directSource = value }
        if parsed.seasonNum > 0, seasonNum != parsed.seasonNum { seasonNum = parsed.seasonNum }
        if parsed.episodeNum > 0, episodeNum != parsed.episodeNum { episodeNum = parsed.episodeNum }
        if let value = parsed.durationSecs, value > 0, durationSecs != value { durationSecs = value }
        if let value = parsed.rating, value.isFinite, value > 0, rating != value { rating = value }
        for (keyPath, value) in [
            (\Episode.movieImage, parsed.movieImage),
            (\Episode.airDate, parsed.airDate),
            (\Episode.plot, parsed.plot)
        ] {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  self[keyPath: keyPath] != value else { continue }
            self[keyPath: keyPath] = value
        }
    }
}

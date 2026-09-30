//
//  TraktPendingWatched.swift
//  Lume
//
//  Holds the watched — and paused — episodes a Trakt import could not apply yet.
//
//  Xtream and Stalker only expose episodes through a per-series
//  `get_series_info` call that the series detail screen makes on first open, so
//  a show the user has never opened has a `Series` row and no `Episode` rows.
//  Fetching them all at import time would mean one request per watched show —
//  roughly 250 KB each, so tens of megabytes and minutes of waiting for a
//  hundred shows — to populate episodes nobody is looking at yet.
//
//  Instead the import parks that state here, keyed by the show's TMDB id, and
//  `Series.insertEpisodes` applies it when the detail screen materializes the
//  episodes anyway. Zero extra provider requests; the ticks are simply in place
//  the first time the user opens the series.
//
//  Derived state, not user data: it is rebuilt by the next import, excluded from
//  backup, and an entry is pruned once it has been applied.
//

import Foundation
import OSLog

/// The watched episodes of one show, as `season × episode → last watched`.
/// Dates are epoch seconds so the on-disk form stays compact — a hundred shows
/// of a long-running series is ~120 KB rather than ~1 MB of ISO-8601 strings.
nonisolated struct TraktPendingShow: Codable, Equatable {
    /// Keys are `"<season>x<episode>"`; values are epoch seconds, or nil when
    /// Trakt reported no timestamp for that episode.
    var episodes: [String: Int?]
    /// Episodes paused part-way (`TraktPlaybackImporter`), keyed like
    /// `episodes`. Optional so a file written before pauses were parked still
    /// decodes.
    var paused: [String: TraktPendingPause]?

    init(episodes: [String: Int?] = [:], paused: [String: TraktPendingPause]? = nil) {
        self.episodes = episodes
        self.paused = paused
    }

    static func key(season: Int, episode: Int) -> String {
        "\(season)x\(episode)"
    }

    var isEmpty: Bool {
        episodes.isEmpty && (paused ?? [:]).isEmpty
    }
}

/// One paused episode waiting for its row.
nonisolated struct TraktPendingPause: Codable, Equatable {
    /// Trakt's percent, 0...100. Kept as a percent: seconds need the
    /// episode's duration, which arrives with the episode.
    var progress: Double
    /// When Trakt paused it, epoch seconds.
    var pausedAt: Int
    /// When the import parked it, epoch seconds. Unlike watched state, a pause
    /// outlives its series' first fetch — the provider may be a season behind
    /// Trakt and list the episode later — so it needs its own expiry.
    var parkedAt: Int
}

/// The parked watched state, keyed by the show's TMDB id (as a string, so the
/// whole thing is a plain JSON object).
nonisolated struct TraktPendingWatched: Codable, Equatable {
    var shows: [String: TraktPendingShow] = [:]

    static let empty = TraktPendingWatched()

    var isEmpty: Bool {
        shows.isEmpty
    }

    subscript(tmdbID: Int) -> TraktPendingShow? {
        get { shows[String(tmdbID)] }
        set { shows[String(tmdbID)] = newValue }
    }
}

/// Reads and writes ``TraktPendingWatched`` on disk, caching it in memory so the
/// per-series lookup in `insertEpisodes` costs nothing after the first hit.
enum TraktPendingWatchedStore {
    private nonisolated(unsafe) static var cached: TraktPendingWatched?
    private static let lock = NSLock()

    /// The directory the parked state is kept in. The unit tests run inside
    /// the installed app, so the test bundle points this at a temporary
    /// directory before any test runs (`PendingStoreIsolation`).
    nonisolated(unsafe) static var directory: URL? = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first

    /// Where the parked state lives. Excluded from backup — the next import
    /// rebuilds it from Trakt.
    static var fileURL: URL? {
        directory?.appendingPathComponent("TraktPendingWatched.json")
    }

    static func load() -> TraktPendingWatched {
        lock.withLock {
            if let cached {
                return cached
            }
            guard let url = fileURL, let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(TraktPendingWatched.self, from: data)
            else {
                cached = .empty
                return .empty
            }
            cached = decoded
            return decoded
        }
    }

    static func save(_ state: TraktPendingWatched) {
        lock.withLock {
            cached = state
            guard let url = fileURL else { return }
            // Nothing left to apply — drop the file rather than leaving an empty
            // object behind.
            guard !state.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            do {
                try JSONEncoder().encode(state).write(to: url, options: .atomic)
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                var mutable = url
                try? mutable.setResourceValues(resourceValues)
            } catch {
                let reason = error.localizedDescription
                Logger.database.error("Trakt pending watched save failed: \(reason, privacy: .public)")
            }
        }
    }

    /// Removes one show's parked state, after its episodes have been marked.
    static func clear(tmdbID: Int) {
        var state = load()
        guard state[tmdbID] != nil else { return }
        state[tmdbID] = nil
        save(state)
    }

    /// Drops everything — used when disconnecting the Trakt account, so a
    /// stale import can't keep marking episodes for a signed-out user.
    static func clearAll() {
        save(.empty)
    }

    /// Test seam: forgets the in-memory copy so the next `load()` re-reads disk.
    static func resetCacheForTesting() {
        lock.withLock { cached = nil }
    }
}

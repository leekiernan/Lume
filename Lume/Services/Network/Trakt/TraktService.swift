//
//  TraktService.swift
//  Lume
//
//  The app-wide coordinator for the Trakt integration. Owns the OAuth token
//  lifecycle (device-flow connect, refresh, disconnect), exposes connection
//  state for the Settings UI to observe, and provides durable user mutations,
//  watchlist fetching, and transient playback scrobbling.
//
//  A shared singleton because watched-state changes originate from many places
//  (player completion, detail-screen toggles, model methods) that don't all
//  have access to the SwiftUI environment. It's still `@Observable`, so views
//  observe `TraktService.shared` directly.
//

import Foundation
import OSLog
import SwiftData
import SwiftUI

@MainActor
@Observable
final class TraktService {
    static let shared = TraktService()

    /// Sign-in and tokens — shared with Simkl, see `TrackerAccountSession`.
    let session = TrackerAccountSession(backend: TraktAccountBackend())

    /// The connected Trakt username, or nil when signed out or not yet known.
    var username: String? {
        session.username
    }

    /// The in-flight device code while the user is approving authorization.
    var pendingCode: TraktDeviceCode? {
        session.pendingCode
    }

    /// A human-readable failure from the last connect attempt, surfaced in the
    /// Settings UI. Cleared when a new attempt begins.
    var connectionError: String? {
        session.connectionError
    }

    /// Whether a device-code authorization is in progress.
    var isConnecting: Bool {
        session.isConnecting
    }

    /// Whether a watched-history import is currently running.
    private(set) var isImporting = false

    /// The result of the most recent import, surfaced in the Settings UI.
    /// Cleared when a new import begins.
    private(set) var lastImport: TraktImportSummary?

    /// Durable history/watchlist intent waiting to reach the connected account.
    /// Failed mutations remain here until a later retry succeeds.
    var pendingMutationCount: Int {
        mutations.pendingCount
    }

    var failedMutationCount: Int {
        mutations.failedCount
    }

    var isSyncingMutations: Bool {
        mutations.isSyncing
    }

    var mutationSyncError: String? {
        mutations.syncError
    }

    /// Durable watched/watchlist intent — shared with Simkl, see
    /// `TrackerMutationQueue`.
    let mutations: TrackerMutationQueue<TraktAccountBackend>

    /// Serialises playback events so a slow start request can never arrive
    /// after the pause or stop that followed it.
    private var scrobbleTask: Task<Void, Never>?

    private let client = TraktClient.shared
    private var watchlistTask: Task<[TraktWatchlistItem], Error>?
    private var watchlistTaskAccount: String?
    private var watchlistTaskID: UUID?

    /// The catalog context the connect flow captured, so the history import can
    /// run the moment the device code is approved.
    private var importContext: ModelContext?

    private init() {
        mutations = TrackerMutationQueue(
            session: session,
            outbox: TrackerMutationOutbox(storageKey: TraktAccountBackend.outboxStorageKey)
        )
        mutations.refreshWatchlist = { [weak self] in
            Task { await self?.refreshWatchlistIfNeeded() }
        }
        session.didConnect = { [weak self] in
            // History imports on connect, as Simkl's does; the manual
            // re-import stays available for later.
            guard let self, let context = importContext else { return }
            importContext = nil
            await importWatched(into: context)
        }
    }

    /// Whether the build has Trakt credentials at all. When false the whole
    /// integration is hidden.
    var isConfigured: Bool {
        session.isConfigured
    }

    /// Whether this device holds Trakt tokens. The username can lag behind
    /// (after a reinstall it has to be fetched again).
    var isConnected: Bool {
        session.isConnected
    }

    // MARK: - Lifecycle

    /// Restores a previously connected session at launch, or after iCloud
    /// replaced the tokens. Best-effort.
    func restore() async {
        guard isConfigured else { return }
        switch await session.restore() {
        case .signedOut:
            mutations.refreshStatus()
        case .waiting:
            // A sibling device may currently be rotating the shared single-use
            // refresh token. Keep the local credentials until CloudKit delivers
            // the replacement instead of revoking the whole shared session.
            break
        case .ready:
            mutations.refreshStatus()
            retryPendingMutations()
        }
    }

    // MARK: - Connect (device flow)

    /// Begins the device-flow connect: requests a code, starts polling, and on
    /// approval imports the account's history into the given catalog context.
    /// Passing nil skips the automatic import.
    func connect(into context: ModelContext? = nil) {
        importContext = context
        session.connect()
    }

    /// Cancels an in-progress connect.
    func cancelConnect() {
        session.cancelConnect()
        importContext = nil
    }

    // MARK: - Disconnect

    /// Disconnects: revokes the token server-side (best effort) and clears all
    /// local state.
    func disconnect() async {
        watchlistTask?.cancel()
        watchlistTask = nil
        watchlistTaskID = nil
        scrobbleTask?.cancel()
        scrobbleTask = nil
        mutations.reset()
        await session.disconnect()
        // Parked watched state belongs to the account that was just signed out.
        TraktPendingWatchedStore.clearAll()
        lastImport = nil
        importContext = nil
    }

    // MARK: - Durable mutation sync

    /// Syncs a movie's watched state to Trakt. Captures the TMDB id up front so
    /// the model never crosses an actor boundary. No-ops when not connected or
    /// the movie has no TMDB id.
    func syncWatched(movie: Movie, watched: Bool) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.history, .movie(tmdbID: tmdbID), isPresent: watched)
    }

    /// Syncs an episode's watched state to Trakt using its show's TMDB id plus
    /// the season/episode numbers.
    func syncWatched(episode: Episode, watched: Bool) {
        guard let showTMDBID = episode.series?.tmdbId else { return }
        mutations.enqueue(.history, .episode(showTMDBID: showTMDBID, season: episode.seasonNum, episode: episode.episodeNum), isPresent: watched)
    }

    /// Retries the connected account's durable mutations. The oldest intent is
    /// always sent first; one failure stops the drain so later mutations cannot
    /// overtake it. Calling this while a drain is active is a no-op.
    func retryPendingMutations() {
        mutations.retry()
    }

    // MARK: - Playback scrobbling

    /// Queues a start, pause or stop event for the connected account. These are
    /// deliberately transient: replaying an old lifecycle event after relaunch
    /// would create a stale Now Watching session on Trakt.
    func scrobble(
        _ target: TraktScrobbleTarget,
        action: TraktScrobbleAction,
        progress: Double
    ) {
        guard isConnected else {
            Logger.network.info("Trakt scrobble \(action.rawValue, privacy: .public) skipped: not connected")
            return
        }
        let previous = scrobbleTask
        // The last scrobble — the stop sent as the player closes — usually
        // goes out as the app leaves the foreground (tvOS closes the player on
        // Home). Without asking for background time the request is suspended
        // mid-flight and Trakt shows the title as watching until its runtime
        // runs out.
        let backgroundTime = ScrobbleBackgroundTime.begin()
        scrobbleTask = Task { [weak self] in
            defer { backgroundTime.end() }
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            guard let accessToken = await session.validAccessToken() else {
                Logger.network.warning(
                    "Trakt scrobble \(action.rawValue, privacy: .public) dropped: no valid access token"
                )
                return
            }

            do {
                let recorded = try await client.scrobble(
                    target, action: action, progress: progress, accessToken: accessToken
                )
                // Successes too: without them a log can't tell a scrobble
                // Trakt took from one that was never sent.
                Logger.network.info("""
                Trakt scrobble \(action.rawValue, privacy: .public) at \(progress, format: .fixed(precision: 1))% → \
                recorded \(recorded.action ?? "?", privacy: .public) \
                at \(recorded.progress ?? -1, format: .fixed(precision: 1))%
                """)
            } catch {
                let detail = LogRedaction.describe(error)
                Logger.network.warning(
                    "Trakt scrobble \(action.rawValue, privacy: .public) failed: \(detail, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Watchlist

    /// Fetches the watchlist without collapsing a transport/auth failure into
    /// an authoritative empty result. Feed caches use this to retain stale data
    /// until a later successful revalidation.
    func watchlistItems() async throws -> [TraktWatchlistItem] {
        guard let account = mutations.account else { throw TraktError.notAuthenticated }
        if let watchlistTask, watchlistTaskAccount == account { return try await watchlistTask.value }
        mutations.watchlist.reset(account: account)
        let revision = mutations.watchlist.revision
        let id = UUID()
        let task = Task {
            defer {
                if watchlistTaskID == id { watchlistTask = nil; watchlistTaskID = nil }
            }
            guard let accessToken = await session.validAccessToken(), mutations.account == account else {
                throw TraktError.notAuthenticated
            }
            let items = try await client.watchlist(accessToken: accessToken)
            guard mutations.account == account, watchlistTaskID == id else { throw TraktError.notAuthenticated }
            let targets = Set(items.compactMap { item -> TrackerMutation.Target? in
                if let id = item.movie?.ids.tmdb { return .movie(tmdbID: id) }
                if let id = item.show?.ids.tmdb { return .show(tmdbID: id) }
                return nil
            })
            mutations.updateWatchlist(targets, account: account, revision: revision)
            return items
        }
        watchlistTask = task
        watchlistTaskAccount = account
        watchlistTaskID = id
        return try await task.value
    }

    func refreshWatchlistIfNeeded() async {
        guard let account = mutations.account else { return }
        mutations.watchlist.reset(account: account)
        guard mutations.watchlist.needsRefresh else { return }
        let revision = mutations.watchlist.revision
        _ = try? await watchlistItems()
        // A delivery can invalidate a read while its request is in flight.
        // Revalidate once after joining it, rather than accepting its old list.
        if mutations.account == account, mutations.watchlist.revision != revision, mutations.watchlist.needsRefresh {
            _ = try? await watchlistItems()
        }
    }

    /// Mirrors a local movie favorite to the connected user's Trakt watchlist.
    /// Captures the TMDB id before starting asynchronous work so the SwiftData
    /// model never crosses an actor boundary.
    func syncWatchlist(movie: Movie, watchlisted: Bool) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.watchlist, .movie(tmdbID: tmdbID), isPresent: watchlisted)
    }

    /// Series counterpart
    func syncWatchlist(series: Series, watchlisted: Bool) {
        guard let tmdbID = series.tmdbId else { return }
        mutations.enqueue(.watchlist, .show(tmdbID: tmdbID), isPresent: watchlisted)
    }

    // MARK: - Lists

    /// A token for reading the connected user's private lists in a custom
    /// section, refreshed if stale; nil when not connected. Public lists read
    /// without one.
    func listAccessToken() async -> String? {
        await session.validAccessToken()
    }

    // MARK: - Watched import

    /// Imports the user's Trakt watched history into the local catalog, marking
    /// matching movies and episodes as watched. Writes through `context` (the
    /// catalog container's context the UI binds to); the iCloud reconciler then
    /// mirrors the change to the user's other devices. No-ops when not connected
    /// or an import is already running.
    func importWatched(into context: ModelContext) async {
        guard isConnected, !isImporting else { return }
        isImporting = true
        lastImport = nil
        defer { isImporting = false }

        let container = context.container
        let outcome = await TrackerImportRun(
            begin: { await TrackerScope.begin(after: self.mutations) },
            accessToken: { await self.session.validAccessToken() },
            fetch: { token in
                async let movies = self.client.watchedMovies(accessToken: token)
                async let shows = self.client.watchedShows(accessToken: token)
                let watched = try await (movies: movies, shows: shows)
                // What's paused part-way, for Continue Watching. Best effort:
                // the watched history stands if this fails.
                let paused = try? await self.client.playback(accessToken: token)
                return (movies: watched.movies, shows: watched.shows, paused: paused)
            },
            isCurrent: { $0.isCurrent(isConnected: self.isConnected, account: self.mutations.account, pendingCount: self.mutations.pendingCount) },
            apply: { history, scope in
                await Self.applyImport(
                    movies: history.movies, shows: history.shows, paused: history.paused, container: container,
                    scope: scope
                )
            }
        ).perform()
        switch outcome {
        case .deferred:
            Logger.network.info("Trakt history import deferred: pending local changes or changed scope")
        case .failed:
            lastImport = .failure
        case .discarded:
            Logger.network.info("Trakt history import discarded: account, profile or pending changes moved during the fetch")
        case let .applied(summary):
            lastImport = summary
            Logger.network.info("Trakt history imported: movies \(summary.moviesMarked), episodes \(summary.episodesMarked), paused \(summary.inProgress), failed \(summary.failed)")
        }
    }

    /// Matching the history against the catalog fetches and faults catalog
    /// rows; on the view context that ran on the main thread. A context of its
    /// own, off the main actor, instead — the UI's context picks the change up
    /// on merge. The paused pass follows the watched one, so a title finished
    /// since isn't reopened.
    @concurrent
    private static func applyImport(
        movies: [TraktWatchedMovie],
        shows: [TraktWatchedShow],
        paused: [TraktPlaybackItem]?,
        container: ModelContainer,
        scope: TrackerScope
    ) async -> TraktImportSummary {
        guard scope.matches(.trakt) else { return .failure }
        let context = ModelContext(container)
        var summary = TraktWatchedImporter.apply(movies: movies, shows: shows, in: context, pendingScope: scope)
        if !summary.failed, let paused {
            summary.inProgress = TraktPlaybackImporter.apply(paused, in: context, pendingScope: scope)
            if context.hasChanges { try? context.save() }
        }
        return summary
    }
}

extension Notification.Name {
    /// Posted only for local Trakt authorization changes (connect, refresh, or
    /// disconnect). CloudSyncCoordinator responds by exporting the keychain
    /// state; credentials pulled from CloudKit do not repost it and loop.
    static let lumeTraktCredentialsDidChange = Notification.Name("LumeTraktCredentialsDidChange")
}

/// Background time for one scrobble request, so a stop sent as the app leaves
/// the foreground still reaches Trakt. A no-op where apps aren't suspended.
@MainActor
struct ScrobbleBackgroundTime {
    #if canImport(UIKit)
        private let identifier: UIBackgroundTaskIdentifier

        static func begin() -> ScrobbleBackgroundTime {
            // The expiry handler ends the task the call itself returns, so it
            // reads the identifier through a box filled in afterwards.
            let task = Identifier()
            task.value = UIApplication.shared.beginBackgroundTask(withName: "Trakt scrobble") {
                UIApplication.shared.endBackgroundTask(task.value)
            }
            return ScrobbleBackgroundTime(identifier: task.value)
        }

        @MainActor
        private final class Identifier {
            var value = UIBackgroundTaskIdentifier.invalid
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
        }
    #else
        static func begin() -> ScrobbleBackgroundTime {
            ScrobbleBackgroundTime()
        }

        func end() {}
    #endif
}

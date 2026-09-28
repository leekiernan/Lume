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
    private(set) var pendingMutationCount = 0
    private(set) var failedMutationCount = 0
    private(set) var isSyncingMutations = false
    private(set) var mutationSyncError: String?

    /// Serialises playback events so a slow start request can never arrive
    /// after the pause or stop that followed it.
    private var scrobbleTask: Task<Void, Never>?
    private var mutationDrainTask: Task<Void, Never>?
    private var mutationDrainID: UUID?

    private let client = TraktClient.shared
    private let mutationOutbox = TraktMutationOutbox()

    private init() {
        session.identityDidChange = { [weak self] _, confirmed in
            self?.refreshMutationStatus()
            if confirmed { self?.retryPendingMutations() }
        }
        session.didConnect = { [weak self] in
            self?.refreshMutationStatus()
            self?.retryPendingMutations()
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
            refreshMutationStatus()
        case .waiting:
            // A sibling device may currently be rotating the shared single-use
            // refresh token. Keep the local credentials until CloudKit delivers
            // the replacement instead of revoking the whole shared session.
            break
        case .ready:
            refreshMutationStatus()
            retryPendingMutations()
        }
    }

    // MARK: - Connect (device flow)

    /// Begins the device-flow connect: requests a code and starts polling.
    func connect() {
        session.connect()
    }

    /// Cancels an in-progress connect.
    func cancelConnect() {
        session.cancelConnect()
    }

    // MARK: - Disconnect

    /// Disconnects: revokes the token server-side (best effort) and clears all
    /// local state.
    func disconnect() async {
        scrobbleTask?.cancel()
        scrobbleTask = nil
        mutationDrainTask?.cancel()
        mutationDrainTask = nil
        mutationDrainID = nil
        await session.disconnect()
        // Parked watched state belongs to the account that was just signed out.
        TraktPendingWatchedStore.clearAll()
        lastImport = nil
        pendingMutationCount = 0
        failedMutationCount = 0
        isSyncingMutations = false
        mutationSyncError = nil
    }

    // MARK: - Durable mutation sync

    /// Syncs a movie's watched state to Trakt. Captures the TMDB id up front so
    /// the model never crosses an actor boundary. No-ops when not connected or
    /// the movie has no TMDB id.
    func syncWatched(movie: Movie, watched: Bool) {
        guard let account = mutationAccount, let tmdbID = movie.tmdbId else { return }
        mutationOutbox.enqueue(
            kind: .history,
            target: .movie(tmdbID: tmdbID),
            isPresent: watched,
            account: account
        )
        refreshMutationStatus()
        retryPendingMutations()
    }

    /// Syncs an episode's watched state to Trakt using its show's TMDB id plus
    /// the season/episode numbers.
    func syncWatched(episode: Episode, watched: Bool) {
        guard let account = mutationAccount, let showTMDBID = episode.series?.tmdbId else { return }
        mutationOutbox.enqueue(
            kind: .history,
            target: .episode(
                showTMDBID: showTMDBID,
                season: episode.seasonNum,
                episode: episode.episodeNum
            ),
            isPresent: watched,
            account: account
        )
        refreshMutationStatus()
        retryPendingMutations()
    }

    /// Retries the connected account's durable mutations. The oldest intent is
    /// always sent first; one failure stops the drain so later mutations cannot
    /// overtake it. Calling this while a drain is active is a no-op.
    func retryPendingMutations() {
        guard mutationDrainTask == nil, let account = mutationAccount,
              mutationOutbox.firstMutation(account: account) != nil
        else {
            refreshMutationStatus()
            return
        }

        mutationSyncError = nil
        isSyncingMutations = true
        let drainID = UUID()
        mutationDrainID = drainID
        mutationDrainTask = Task { [weak self] in
            await self?.drainPendingMutations(account: account, drainID: drainID)
        }
    }

    private func drainPendingMutations(account: String, drainID: UUID) async {
        defer {
            if mutationDrainID == drainID {
                mutationDrainTask = nil
                mutationDrainID = nil
                isSyncingMutations = false
                refreshMutationStatus()
            }
        }

        while !Task.isCancelled,
              mutationAccount == account,
              let mutation = mutationOutbox.firstMutation(account: account)
        {
            guard let accessToken = await session.validAccessToken() else {
                mutationOutbox.recordFailure(id: mutation.id, account: account)
                mutationSyncError = "Couldn't sync changes to Trakt. Please try again."
                break
            }

            do {
                guard try await client.apply(mutation, accessToken: accessToken) else {
                    Logger.network.error(
                        "Discarding malformed Trakt \(mutation.kind.rawValue, privacy: .public) mutation"
                    )
                    mutationOutbox.acknowledge(id: mutation.id, account: account)
                    continue
                }
                mutationOutbox.acknowledge(id: mutation.id, account: account)
            } catch {
                mutationOutbox.recordFailure(id: mutation.id, account: account)
                let reason = error.localizedDescription
                Logger.network.warning("Trakt mutation failed: \(reason, privacy: .public)")
                mutationSyncError = "Couldn't sync changes to Trakt. Please try again."
                // If this intent was replaced while its request was in flight,
                // it is no longer the queue head. Continue with the new intent;
                // otherwise preserve strict FIFO ordering and wait for a retry.
                if mutationOutbox.contains(id: mutation.id, account: account) {
                    break
                }
            }
        }
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
        guard isConnected else { return }
        let previous = scrobbleTask
        scrobbleTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self,
                  let accessToken = await session.validAccessToken()
            else { return }

            do {
                try await client.scrobble(
                    target, action: action, progress: progress, accessToken: accessToken
                )
            } catch {
                let detail = LogRedaction.describe(error)
                Logger.network.warning(
                    "Trakt scrobble \(action.rawValue, privacy: .public) failed: \(detail, privacy: .public)"
                )
            }
        }
    }

    private var mutationAccount: String? {
        guard isConnected, let scope = session.identity?.scope, !scope.isEmpty else { return nil }
        return scope
    }

    private func refreshMutationStatus() {
        guard let account = mutationAccount else {
            pendingMutationCount = 0
            failedMutationCount = 0
            mutationSyncError = nil
            return
        }
        let status = mutationOutbox.status(account: account)
        pendingMutationCount = status.pendingCount
        failedMutationCount = status.failedCount
        if status.failedCount == 0 {
            mutationSyncError = nil
        } else if mutationSyncError == nil {
            mutationSyncError = "Some Trakt changes are waiting to retry."
        }
    }

    // MARK: - Watchlist

    /// Fetches the watchlist without collapsing a transport/auth failure into
    /// an authoritative empty result. Feed caches use this to retain stale data
    /// until a later successful revalidation.
    func watchlistItems() async throws -> [TraktWatchlistItem] {
        guard let accessToken = await session.validAccessToken() else {
            throw TraktError.notAuthenticated
        }
        return try await client.watchlist(accessToken: accessToken)
    }

    /// Mirrors a local movie favorite to the connected user's Trakt watchlist.
    /// Captures the TMDB id before starting asynchronous work so the SwiftData
    /// model never crosses an actor boundary.
    func syncWatchlist(movie: Movie, watchlisted: Bool) {
        guard let account = mutationAccount, let tmdbID = movie.tmdbId else { return }
        mutationOutbox.enqueue(
            kind: .watchlist,
            target: .movie(tmdbID: tmdbID),
            isPresent: watchlisted,
            account: account
        )
        refreshMutationStatus()
        retryPendingMutations()
    }

    /// Series counterpart
    func syncWatchlist(series: Series, watchlisted: Bool) {
        guard let account = mutationAccount, let tmdbID = series.tmdbId else { return }
        mutationOutbox.enqueue(
            kind: .watchlist,
            target: .show(tmdbID: tmdbID),
            isPresent: watchlisted,
            account: account
        )
        refreshMutationStatus()
        retryPendingMutations()
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

        guard let accessToken = await session.validAccessToken() else {
            lastImport = .failure
            return
        }
        do {
            let movies = try await client.watchedMovies(accessToken: accessToken)
            let shows = try await client.watchedShows(accessToken: accessToken)
            lastImport = TraktWatchedImporter.apply(movies: movies, shows: shows, in: context)
        } catch {
            lastImport = .failure
        }
    }
}

extension Notification.Name {
    /// Posted only for local Trakt authorization changes (connect, refresh, or
    /// disconnect). CloudSyncCoordinator responds by exporting the keychain
    /// state; credentials pulled from CloudKit do not repost it and loop.
    static let lumeTraktCredentialsDidChange = Notification.Name("LumeTraktCredentialsDidChange")
}

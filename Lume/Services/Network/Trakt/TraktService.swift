//
//  TraktService.swift
//  Lume
//
//  The app-wide coordinator for the Trakt integration. Owns the OAuth token
//  lifecycle (device-flow connect, refresh, disconnect), exposes connection
//  state for the Settings UI to observe, and provides fire-and-forget watched
//  syncing plus watchlist fetching and mutation.
//
//  A shared singleton because watched-state changes originate from many places
//  (player completion, detail-screen toggles, model methods) that don't all
//  have access to the SwiftUI environment. It's still `@Observable`, so views
//  observe `TraktService.shared` directly.
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class TraktService {
    static let shared = TraktService()

    /// The connected Trakt username, or nil when not connected.
    private(set) var username: String?

    /// The in-flight device code while the user is approving authorization.
    private(set) var pendingCode: TraktDeviceCode?

    /// A human-readable failure from the last connect attempt, surfaced in the
    /// Settings UI. Cleared when a new attempt begins.
    private(set) var connectionError: String?

    /// Whether a device-code authorization is currently being polled.
    private(set) var isConnecting = false

    /// Whether a watched-history import is currently running.
    private(set) var isImporting = false

    /// The result of the most recent import, surfaced in the Settings UI.
    /// Cleared when a new import begins.
    private(set) var lastImport: TraktImportSummary?

    private var tokens: TraktTokens?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<String?, Never>?
    /// A refresh token that Trakt rejected. Another device may have consumed
    /// this single-use token and be exporting its replacement through CloudKit,
    /// so suppress repeated retries until a different token arrives.
    private var refreshFailedForToken: String?

    private let client = TraktClient.shared

    private init() {}

    /// Whether the build has Trakt credentials at all. When false the whole
    /// integration is hidden.
    var isConfigured: Bool {
        client.isConfigured
    }

    var isConnected: Bool {
        username != nil
    }

    // MARK: - Lifecycle

    /// Restores a previously connected session at launch: loads the stored
    /// tokens, refreshes them if stale, and fetches the username. Best-effort.
    func restore() async {
        guard isConfigured else { return }
        guard let stored = TraktTokenStore.load() else {
            tokens = nil
            username = nil
            refreshFailedForToken = nil
            return
        }
        tokens = stored
        if refreshFailedForToken != stored.refreshToken {
            refreshFailedForToken = nil
        }
        guard let accessToken = await validAccessToken() else {
            // A sibling device may currently be rotating the shared single-use
            // refresh token. Keep the local credentials until CloudKit delivers
            // the replacement instead of revoking the whole shared session.
            return
        }
        username = try? await client.currentUser(accessToken: accessToken).username
    }

    // MARK: - Connect (device flow)

    /// Begins the device-flow connect: requests a code and starts polling.
    func connect() {
        guard isConfigured, !isConnecting else { return }
        connectionError = nil
        isConnecting = true

        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            await self?.runDeviceFlow()
        }
    }

    /// Cancels an in-progress connect.
    func cancelConnect() {
        pollingTask?.cancel()
        pollingTask = nil
        pendingCode = nil
        isConnecting = false
    }

    private func runDeviceFlow() async {
        do {
            let code = try await client.requestDeviceCode()
            pendingCode = code

            let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            var interval = TimeInterval(max(code.interval, 1))

            while !Task.isCancelled, Date() < deadline {
                try await Task.sleep(for: .seconds(interval))
                if Task.isCancelled {
                    return
                }

                do {
                    let response = try await client.pollForToken(deviceCode: code.deviceCode)
                    await finishConnect(with: response)
                    return
                } catch TraktError.authorizationPending {
                    continue
                } catch TraktError.slowDown {
                    interval += 1
                    continue
                } catch TraktError.codeExpired {
                    failConnect("The code expired. Please try connecting again.")
                    return
                } catch TraktError.codeDenied {
                    failConnect("Authorization was declined.")
                    return
                } catch TraktError.codeUsed {
                    failConnect("That code was already used. Please try again.")
                    return
                }
            }

            if !Task.isCancelled {
                failConnect("The code expired. Please try connecting again.")
            }
        } catch is CancellationError {
            // Cancelled via cancelConnect() — state already reset there.
        } catch {
            failConnect("Couldn't reach Trakt. Check your connection and try again.")
        }
    }

    private func finishConnect(with response: TraktTokenResponse) async {
        applyTokens(response.tokens)
        username = try? await client.currentUser(accessToken: response.accessToken).username
        pendingCode = nil
        isConnecting = false
        connectionError = nil
    }

    private func failConnect(_ message: String) {
        connectionError = message
        pendingCode = nil
        isConnecting = false
    }

    // MARK: - Disconnect

    /// Disconnects: revokes the token server-side (best effort) and clears all
    /// local state.
    func disconnect() async {
        pollingTask?.cancel()
        pollingTask = nil
        if let accessToken = tokens?.accessToken {
            try? await client.revokeToken(accessToken)
        }
        if TraktTokenStore.clear() {
            NotificationCenter.default.post(name: .lumeTraktCredentialsDidChange, object: nil)
        }
        // Parked watched state belongs to the account that was just signed out.
        TraktPendingWatchedStore.clearAll()
        tokens = nil
        username = nil
        pendingCode = nil
        isConnecting = false
        lastImport = nil
    }

    // MARK: - Watched sync (fire-and-forget)

    /// Syncs a movie's watched state to Trakt. Captures the TMDB id up front so
    /// the model never crosses an actor boundary. No-ops when not connected or
    /// the movie has no TMDB id.
    func syncWatched(movie: Movie, watched: Bool) {
        guard isConnected, let tmdbID = movie.tmdbId else { return }
        let items = TraktSyncItems.movie(tmdbID: tmdbID)
        syncHistory(items, add: watched)
    }

    /// Syncs an episode's watched state to Trakt using its show's TMDB id plus
    /// the season/episode numbers.
    func syncWatched(episode: Episode, watched: Bool) {
        guard isConnected, let showTMDBID = episode.series?.tmdbId else { return }
        let items = TraktSyncItems.episode(
            showTMDBID: showTMDBID,
            season: episode.seasonNum,
            episode: episode.episodeNum
        )
        syncHistory(items, add: watched)
    }

    private func syncHistory(_ items: TraktSyncItems, add: Bool) {
        Task { [weak self] in
            guard let self, let accessToken = await validAccessToken() else { return }
            do {
                if add {
                    try await client.addToHistory(items, accessToken: accessToken)
                } else {
                    try await client.removeFromHistory(items, accessToken: accessToken)
                }
            } catch {
                // Scrobbling is best-effort; a failed sync shouldn't disrupt
                // playback or the UI.
            }
        }
    }

    // MARK: - Watchlist

    /// Fetches the user's watchlist. Returns an empty array when not connected
    /// or on error — the home row simply hides.
    func fetchWatchlist() async -> [TraktWatchlistItem] {
        guard let accessToken = await validAccessToken() else { return [] }
        return await (try? client.watchlist(accessToken: accessToken)) ?? []
    }

    /// Mirrors a local movie favorite to the connected user's Trakt watchlist.
    /// Captures the TMDB id before starting asynchronous work so the SwiftData
    /// model never crosses an actor boundary.
    func syncWatchlist(movie: Movie, watchlisted: Bool) {
        guard isConnected, let tmdbID = movie.tmdbId else { return }
        syncWatchlist(.movie(tmdbID: tmdbID), add: watchlisted)
    }

    /// Series counterpart
    func syncWatchlist(series: Series, watchlisted: Bool) {
        guard isConnected, let tmdbID = series.tmdbId else { return }
        syncWatchlist(.show(tmdbID: tmdbID), add: watchlisted)
    }

    private func syncWatchlist(_ items: TraktWatchlistSyncItems, add: Bool) {
        Task { [weak self] in
            guard let self, let accessToken = await validAccessToken() else { return }
            do {
                if add {
                    try await client.addToWatchlist(items, accessToken: accessToken)
                } else {
                    try await client.removeFromWatchlist(items, accessToken: accessToken)
                }
            } catch {
                // Favorite changes are local-first and Trakt sync is best-effort;
                // a network failure must not roll back or interrupt the UI.
            }
        }
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

        guard let accessToken = await validAccessToken() else {
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

    // MARK: - Tokens

    /// Returns a usable access token, refreshing first if it's stale. Coalesces
    /// concurrent refreshes into a single request.
    private func validAccessToken() async -> String? {
        guard let current = tokens else { return nil }
        if !current.needsRefresh {
            return current.accessToken
        }
        // Trakt refresh tokens are single-use. A rejection commonly means a
        // sibling device refreshed first; wait for its CloudKit update instead
        // of hammering the same invalid token or disconnecting every device.
        guard refreshFailedForToken != current.refreshToken else { return nil }

        if let refreshTask {
            return await refreshTask.value
        }

        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            do {
                let response = try await client.refreshToken(current.refreshToken)
                applyTokens(response.tokens)
                return tokens?.accessToken
            } catch let error as TraktError {
                // Only suppress another attempt when Trakt actually rejected
                // the token. Transient transport and server failures should be
                // retried the next time an authenticated operation runs.
                switch error {
                case .server(400), .notAuthenticated:
                    if tokens?.refreshToken == current.refreshToken {
                        refreshFailedForToken = current.refreshToken
                    }
                default:
                    break
                }
                return nil
            } catch {
                return nil
            }
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func applyTokens(_ newTokens: TraktTokens) {
        // An older in-flight refresh must never overwrite a newer token pair
        // that just arrived from CloudKit.
        if let current = tokens, current.createdAt > newTokens.createdAt {
            return
        }
        tokens = newTokens
        refreshFailedForToken = nil
        if TraktTokenStore.save(newTokens) {
            NotificationCenter.default.post(name: .lumeTraktCredentialsDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted only for local Trakt authorization changes (connect, refresh, or
    /// disconnect). CloudSyncCoordinator responds by exporting the keychain
    /// state; credentials pulled from CloudKit do not repost it and loop.
    static let lumeTraktCredentialsDidChange = Notification.Name("LumeTraktCredentialsDidChange")
}

//
//  SimklService.swift
//  Lume
//
//  The app-wide coordinator for the Simkl integration. Owns the OAuth token
//  lifecycle (device-flow connect, refresh, disconnect), exposes connection
//  state for the Settings UI to observe, and queues watched changes in a
//  durable outbox. Mirrors `TraktService` against the Simkl AUTH V2 API.
//
//  A shared singleton because watched-state changes originate from many places
//  (player completion, detail-screen toggles, model methods) that don't all
//  have access to the SwiftUI environment. It's still `@Observable`, so views
//  observe `SimklService.shared` directly. Watched mutations use the same
//  durable account-scoped outbox contract as Trakt; playback scrobbles remain
//  deliberately unsupported by Simkl for now.
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SimklService {
    static let shared = SimklService()

    /// The connected Simkl username, or nil when not connected.
    private(set) var username: String?

    /// The in-flight device code while the user is approving authorization.
    private(set) var pendingCode: SimklDeviceCode?

    /// A human-readable failure from the last connect attempt, surfaced in the
    /// Settings UI. Cleared when a new attempt begins.
    private(set) var connectionError: String?

    /// Whether a device-code authorization is currently being polled.
    private(set) var isConnecting = false

    /// Whether a watched-history import is currently running.
    private(set) var isImporting = false

    /// The result of the most recent import, surfaced in the Settings UI.
    /// Cleared when a new import begins.
    private(set) var lastImport: SimklImportSummary?

    /// Mirrors Trakt's durable-history status so a temporary network failure
    /// cannot silently lose a local watched/unwatched choice.
    private(set) var pendingMutationCount = 0
    private(set) var failedMutationCount = 0
    private(set) var isSyncingMutations = false
    private(set) var mutationSyncError: String?

    private var tokens: SimklTokens?
    /// The outbox partition for the connected account; see
    /// `SimklAccountIdentity.scope`.
    private var mutationAccountScope: String?
    /// A refresh token Simkl rejected, so it isn't retried on every call.
    /// Simkl's refresh token doesn't rotate, so a rejection means it was revoked
    /// or expired; the pair is kept rather than erased, because clearing it
    /// would sync the disconnect to every device, and a re-authorized pair may
    /// still arrive through CloudKit.
    private var refreshFailedForToken: String?
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<String?, Never>?
    private var mutationDrainTask: Task<Void, Never>?
    private var mutationDrainID: UUID?

    /// The catalog context the connect flow captured, so the watched-history
    /// import can run the moment the device code is approved.
    private var importContext: ModelContext?

    private let client = SimklClient.shared
    private let mutationOutbox = TrackerMutationOutbox(storageKey: "simkl.mutationOutbox.v1")

    private init() {}

    /// Whether the build has Simkl credentials at all. When false the whole
    /// integration is hidden.
    var isConfigured: Bool {
        client.isConfigured
    }

    var isConnected: Bool {
        username != nil
    }

    // MARK: - Lifecycle

    /// Restores a previously connected session at launch: loads the stored
    /// tokens and the remembered account identity, refreshes the tokens if
    /// stale, and re-fetches the identity. Best-effort — offline, the
    /// remembered identity keeps the account connected so watched changes
    /// still queue.
    func restore() async {
        guard isConfigured else { return }
        guard let stored = SimklTokenStore.load() else {
            tokens = nil
            username = nil
            mutationAccountScope = nil
            SimklAccountIdentityStore.clear()
            refreshFailedForToken = nil
            refreshMutationStatus()
            return
        }
        tokens = stored
        username = nil
        mutationAccountScope = nil
        if let identity = SimklAccountIdentityStore.load() {
            username = identity.username
            mutationAccountScope = identity.scope
        }
        if refreshFailedForToken != stored.refreshToken {
            refreshFailedForToken = nil
        }
        guard let accessToken = await validAccessToken() else {
            // Offline, or the refresh was rejected. Keep the pair: the
            // remembered identity still queues changes, and a re-authorized
            // pair may yet arrive through CloudKit.
            return
        }
        if let settings = try? await client.userSettings(accessToken: accessToken) {
            applyAccountIdentity(settings)
        }
        refreshMutationStatus()
        retryPendingMutations()
    }

    // MARK: - Connect (device flow)

    /// Begins the device-flow connect: requests a code, starts polling, and on
    /// approval imports the account's watched history into the given catalog
    /// context. Passing nil skips the automatic import.
    func connect(into context: ModelContext? = nil) {
        guard isConfigured, !isConnecting else { return }
        connectionError = nil
        isConnecting = true
        importContext = context

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
        importContext = nil
    }

    private func runDeviceFlow() async {
        do {
            let code = try await client.requestDeviceCode()
            pendingCode = code

            let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            var interval = TimeInterval(max(code.interval, 1))

            // A declined code is indistinguishable from an untouched one —
            // Simkl records nothing on decline — so the `expiresIn` deadline is
            // the only way this loop ends for a user who says no.
            while !Task.isCancelled, Date() < deadline {
                try await Task.sleep(for: .seconds(interval))
                if Task.isCancelled {
                    return
                }

                do {
                    let response = try await client.pollForToken(deviceCode: code.deviceCode)
                    await finishConnect(with: response)
                    return
                } catch SimklError.authorizationPending {
                    continue
                } catch SimklError.slowDown {
                    // Simkl asks for a flat +5 s on slow-down; retrying at the
                    // old cadence re-arms their poll window and locks the loop
                    // out until the code expires.
                    interval += 5
                    continue
                } catch SimklError.codeExpired {
                    failConnect("The code expired. Please try connecting again.")
                    return
                } catch SimklError.invalidClient {
                    failConnect("Simkl rejected this app's credentials.")
                    return
                }
            }

            if !Task.isCancelled {
                failConnect("The code expired. Please try connecting again.")
            }
        } catch is CancellationError {
            // Cancelled via cancelConnect() — state already reset there.
        } catch {
            failConnect("Couldn't reach Simkl. Check your connection and try again.")
        }
    }

    private func finishConnect(with response: SimklTokenResponse) async {
        applyTokens(response.tokens)
        if let settings = try? await client.userSettings(accessToken: response.accessToken) {
            applyAccountIdentity(settings)
        }
        pendingCode = nil
        isConnecting = false
        connectionError = nil
        refreshMutationStatus()
        retryPendingMutations()

        // The issue's contract: the account's watched history imports on
        // connect, not only on demand. Runs on the context the connect call
        // captured; the manual re-import below stays available for later.
        if let context = importContext {
            importContext = nil
            await importWatched(into: context)
        }
    }

    private func failConnect(_ message: String) {
        connectionError = message
        pendingCode = nil
        isConnecting = false
        importContext = nil
    }

    // MARK: - Disconnect

    /// Disconnects: revokes the token server-side (best effort) and clears all
    /// local state.
    func disconnect() async {
        pollingTask?.cancel()
        pollingTask = nil
        mutationDrainTask?.cancel()
        mutationDrainTask = nil
        mutationDrainID = nil
        if let accessToken = tokens?.accessToken {
            try? await client.revokeToken(accessToken)
        }
        if SimklTokenStore.clear() {
            NotificationCenter.default.post(name: .lumeSimklCredentialsDidChange, object: nil)
        }
        SimklAccountIdentityStore.clear()
        // Parked watched state belongs to the account that was just signed out.
        SimklPendingWatchedStore.clearAll()
        tokens = nil
        username = nil
        mutationAccountScope = nil
        pendingCode = nil
        isConnecting = false
        lastImport = nil
        importContext = nil
        pendingMutationCount = 0
        failedMutationCount = 0
        isSyncingMutations = false
        mutationSyncError = nil
    }

    // MARK: - Durable watched sync

    /// Queues a movie's watched state for Simkl. Captures the TMDB id up front
    /// so the model never crosses an actor boundary; Simkl resolves the title
    /// from it. No-ops when not connected or the movie has no TMDB id.
    func syncWatched(movie: Movie, watched: Bool) {
        guard let account = mutationAccount, let tmdbID = movie.tmdbId else { return }
        mutationOutbox.enqueue(target: .movie(tmdbID: tmdbID), watched: watched, account: account)
        refreshMutationStatus()
        retryPendingMutations()
    }

    /// Syncs an episode's watched state to Simkl using its show's TMDB id plus
    /// the season/episode numbers.
    func syncWatched(episode: Episode, watched: Bool) {
        guard let account = mutationAccount, let showTMDBID = episode.series?.tmdbId else { return }
        mutationOutbox.enqueue(
            target: .episode(showTMDBID: showTMDBID, season: episode.seasonNum, episode: episode.episodeNum),
            watched: watched,
            account: account
        )
        refreshMutationStatus()
        retryPendingMutations()
    }

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
            guard let accessToken = await validAccessToken() else {
                mutationOutbox.recordFailure(id: mutation.id, account: account)
                mutationSyncError = "Couldn't sync changes to Simkl. Please try again."
                break
            }
            do {
                guard let items = historyItems(for: mutation.target) else {
                    // The shared queue can represent Trakt's show-watchlist
                    // target, but Simkl history has no equivalent request.
                    // It cannot originate from Simkl's enqueue sites, so drop
                    // it defensively rather than blocking the account forever.
                    mutationOutbox.acknowledge(id: mutation.id, account: account)
                    continue
                }
                if mutation.watched {
                    try await client.addToHistory(items, accessToken: accessToken)
                } else {
                    try await client.removeFromHistory(items, accessToken: accessToken)
                }
                mutationOutbox.acknowledge(id: mutation.id, account: account)
            } catch {
                mutationOutbox.recordFailure(id: mutation.id, account: account)
                mutationSyncError = "Couldn't sync changes to Simkl. Please try again."
                if mutationOutbox.contains(id: mutation.id, account: account) { break }
            }
        }
    }

    private func historyItems(for target: TrackerHistoryMutation.Target) -> SimklSyncItems? {
        switch target {
        case let .movie(tmdbID): SimklSyncItems.movie(tmdbID: tmdbID, title: nil)
        case .show: nil
        case let .episode(showTMDBID, season, episode):
            SimklSyncItems.episode(showTMDBID: showTMDBID, showTitle: nil, season: season, episode: episode)
        }
    }

    private var mutationAccount: String? {
        guard isConnected, let mutationAccountScope, !mutationAccountScope.isEmpty else { return nil }
        return mutationAccountScope
    }

    private func applyAccountIdentity(_ settings: SimklUserSettings) {
        let identity = SimklAccountIdentity(settings: settings)
        username = identity.username
        mutationAccountScope = identity.scope
        mutationOutbox.adoptMutations(from: identity.legacyScope, into: identity.scope)
        SimklAccountIdentityStore.save(identity)
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
            mutationSyncError = "Some Simkl changes are waiting to retry."
        }
    }

    // MARK: - Playback scrobbling

    /// Simkl deliberately has no playback implementation yet. Keeping the
    /// same API as Trakt lets a tracker dispatcher call both services without
    /// claiming that old start/pause events are durable user intent.
    func scrobble(_ target: TraktScrobbleTarget, action: TraktScrobbleAction, progress: Double) {
        _ = (target, action, progress)
    }

    // MARK: - Watched import

    /// Imports the user's Simkl watched history into the local catalog, marking
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
            let items = try await client.watchedItems(accessToken: accessToken)
            lastImport = SimklWatchedImporter.apply(items: items, in: context)
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
            } catch let error as SimklError {
                switch error {
                // A rejected refresh token comes back as an OAuth error
                // envelope at 400; `postOAuth` never throws notAuthenticated.
                case .server(400):
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

    private func applyTokens(_ newTokens: SimklTokens) {
        if let current = tokens, current.issuedAt > newTokens.issuedAt {
            return
        }
        tokens = newTokens
        refreshFailedForToken = nil
        if SimklTokenStore.save(newTokens) {
            NotificationCenter.default.post(name: .lumeSimklCredentialsDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted only for local Simkl authorization changes. CloudKit pulls do not
    /// repost it, preventing an import/export feedback loop.
    static let lumeSimklCredentialsDidChange = Notification.Name("LumeSimklCredentialsDidChange")
}

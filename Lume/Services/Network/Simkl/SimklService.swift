//
//  SimklService.swift
//  Lume
//
//  The app-wide coordinator for the Simkl integration. Owns the OAuth token
//  lifecycle (device-flow connect, refresh, disconnect), exposes connection
//  state for the Settings UI to observe, queues watched changes in a durable
//  outbox, and fetches the watchlist for Home. Mirrors `TraktService` against
//  the Simkl AUTH V2 API.
//
//  A shared singleton because watched-state changes originate from many places
//  (player completion, detail-screen toggles, model methods) that don't all
//  have access to the SwiftUI environment. It's still `@Observable`, so views
//  observe `SimklService.shared` directly. Watched mutations use the same
//  durable account-scoped outbox contract as Trakt; playback scrobbles remain
//  deliberately unsupported by Simkl for now.
//

import Foundation
import OSLog
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SimklService {
    static let shared = SimklService()

    /// Sign-in and tokens — shared with Trakt, see `TrackerAccountSession`.
    let session: TrackerAccountSession<SimklAccountBackend>

    /// The connected Simkl username, or nil when signed out or not yet known.
    var username: String? {
        session.username
    }

    /// The in-flight device code while the user is approving authorization.
    var pendingCode: SimklDeviceCode? {
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
    private(set) var lastImport: SimklImportSummary?

    /// Mirrors Trakt's durable-history status so a temporary network failure
    /// cannot silently lose a local watched/unwatched choice.
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

    /// Durable watched intent — shared with Trakt, see `TrackerMutationQueue`.
    let mutations: TrackerMutationQueue<SimklAccountBackend>

    private var watchlistTask: Task<[SimklWatchlistEntry], Never>?

    /// The catalog context the connect flow captured, so the watched-history
    /// import can run the moment the device code is approved.
    private var importContext: ModelContext?

    private let client: SimklClient

    init(client: SimklClient = .shared, outbox: TrackerMutationOutbox? = nil) {
        self.client = client
        let session = TrackerAccountSession(backend: SimklAccountBackend(client: client))
        self.session = session
        mutations = TrackerMutationQueue(
            session: session,
            outbox: outbox ?? TrackerMutationOutbox(storageKey: SimklAccountBackend.outboxStorageKey)
        )
        session.didConnect = { [weak self] in
            // The account's watched history imports on connect, not only on
            // demand. Runs on the context the connect call captured; the manual
            // re-import stays available for later.
            guard let self, let context = importContext else { return }
            importContext = nil
            await importWatched(into: context)
        }
    }

    /// Whether the build has Simkl credentials at all. When false the whole
    /// integration is hidden.
    var isConfigured: Bool {
        session.isConfigured
    }

    /// Whether this device holds Simkl tokens. The username can lag behind
    /// (after a reinstall it has to be fetched again).
    var isConnected: Bool {
        session.isConnected
    }

    // MARK: - Lifecycle

    /// Restores a previously connected session at launch, or after iCloud
    /// replaced the tokens. Best-effort — offline, the remembered identity
    /// keeps the account connected so watched changes still queue.
    func restore() async {
        guard isConfigured else { return }
        switch await session.restore() {
        case .signedOut:
            // Signed out elsewhere (the credential left through iCloud): the
            // cached watchlist belongs to that account.
            SimklWatchlistStore.clear()
            mutations.refreshStatus()
        case .waiting:
            // Offline, or the refresh was rejected. Keep the pair: the
            // remembered identity still queues changes, and a re-authorized
            // pair may yet arrive through CloudKit.
            break
        case .ready:
            mutations.refreshStatus()
            retryPendingMutations()
        }
    }

    // MARK: - Connect (device flow)

    /// Begins the device-flow connect: requests a code, starts polling, and on
    /// approval imports the account's watched history into the given catalog
    /// context. Passing nil skips the automatic import.
    func connect(into context: ModelContext? = nil) {
        guard !isConnecting else { return }
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
        mutations.reset()
        await session.disconnect()
        // Parked watched state belongs to the account that was just signed out.
        SimklPendingWatchedStore.clearAll()
        SimklWatchlistStore.clear()
        lastImport = nil
        importContext = nil
    }

    // MARK: - Durable watched sync

    /// Queues a movie's watched state for Simkl. Captures the TMDB id up front
    /// so the model never crosses an actor boundary; Simkl resolves the title
    /// from it. No-ops when not connected or the movie has no TMDB id.
    func syncWatched(movie: Movie, watched: Bool) {
        guard let tmdbID = movie.tmdbId else { return }
        mutations.enqueue(.history, .movie(tmdbID: tmdbID), isPresent: watched)
    }

    /// Syncs an episode's watched state to Simkl using its show's TMDB id plus
    /// the season/episode numbers.
    func syncWatched(episode: Episode, watched: Bool) {
        guard let showTMDBID = episode.series?.tmdbId else { return }
        mutations.enqueue(.history, .episode(showTMDBID: showTMDBID, season: episode.seasonNum, episode: episode.episodeNum), isPresent: watched)
    }

    /// Retries the connected account's durable mutations, oldest first.
    func retryPendingMutations() {
        mutations.retry()
    }

    // MARK: - Playback scrobbling

    /// Simkl deliberately has no playback implementation yet. Keeping the
    /// same API as Trakt lets a tracker dispatcher call both services without
    /// claiming that old start/pause events are durable user intent.
    func scrobble(_ target: TraktScrobbleTarget, action: TraktScrobbleAction, progress: Double) {
        _ = (target, action, progress)
    }

    // MARK: - Watchlist

    /// The user's "Plan to Watch" titles, most recently added first. Served
    /// from the on-disk copy, refetching only the buckets `/sync/activities`
    /// says have moved (see `SimklWatchlist.swift`). Returns an empty array when
    /// not connected; on error it falls back to the cached copy, so the home row
    /// keeps what it last showed rather than blinking out.
    func fetchWatchlist() async -> [SimklWatchlistEntry] {
        if let watchlistTask {
            return await watchlistTask.value
        }
        let task = Task { [weak self] () -> [SimklWatchlistEntry] in
            await self?.loadWatchlist() ?? []
        }
        watchlistTask = task
        let result = await task.value
        watchlistTask = nil
        return result
    }

    private func loadWatchlist() async -> [SimklWatchlistEntry] {
        guard let username, let accessToken = await session.validAccessToken() else { return [] }
        var cache = SimklWatchlistStore.load(for: username) ?? SimklWatchlistCache(username: username)
        guard let activities = try? await client.activities(accessToken: accessToken) else {
            return cache.entries
        }
        let original = cache
        for bucket in cache.staleBuckets(for: activities) {
            guard let fingerprint = activities.fingerprint(for: bucket) else {
                cache.buckets[bucket] = SimklWatchlistCache.Bucket(fingerprint: nil, entries: [])
                continue
            }
            // A failed bucket keeps its old copy and fingerprint, so the next
            // Home load retries it.
            guard let entries = try? await client.planToWatch(bucket, accessToken: accessToken) else { continue }
            cache.buckets[bucket] = SimklWatchlistCache.Bucket(fingerprint: fingerprint, entries: entries)
        }
        // A disconnect mid-fetch already cleared the store; writing now would
        // resurrect the signed-out account's list.
        guard self.username == username else { return [] }
        if cache != original {
            SimklWatchlistStore.save(cache)
        }
        return cache.entries
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

        // Same scope rule as Trakt: local changes go up first, and the history
        // is applied only to the account and profile it was fetched for.
        let container = context.container
        let outcome = await TrackerImportRun(
            begin: { await TrackerImportScope.begin(after: self.mutations) },
            accessToken: { await self.session.validAccessToken() },
            fetch: { try await self.client.watchedItems(accessToken: $0) },
            isCurrent: { $0.isCurrent(isConnected: self.isConnected, account: self.mutations.account, pendingCount: self.mutations.pendingCount) },
            apply: { items, scope in await Self.applyImport(items: items, container: container, profileID: scope.profileID, accountID: scope.account) }
        ).perform()
        switch outcome {
        case .deferred:
            Logger.network.info("Simkl history import deferred: pending local changes or changed scope")
        case .failed:
            lastImport = .failure
        case .discarded:
            Logger.network.info("Simkl history import discarded: account, profile or pending changes moved during the fetch")
        case let .applied(summary):
            lastImport = summary
        }
    }

    /// Off the main actor, on a context of its own — see `TraktService`.
    @concurrent
    static func applyImport(items: SimklAllItems, container: ModelContainer, profileID: UUID?, accountID: String?) async -> SimklImportSummary {
        let scope = TrackerProgressScope(profileID: profileID, accountID: accountID)
        guard scope.matches(.simkl) else { return .failure }
        return SimklWatchedImporter.apply(items: items, in: ModelContext(container), pendingScope: scope)
    }
}

extension Notification.Name {
    /// Posted only for local Simkl authorization changes. CloudKit pulls do not
    /// repost it, preventing an import/export feedback loop.
    static let lumeSimklCredentialsDidChange = Notification.Name("LumeSimklCredentialsDidChange")
}

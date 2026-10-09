//
//  EPGSyncService.swift
//  Lume
//
//  Owns the background EPG refresh task and publishes whether one is running,
//  for the EPG settings screen. Singleton because it must outlive any one view
//  and be reachable from launch, the content-sync completion hook, and the
//  manual "Sync Now" button.
//

import Foundation
import Observation
import OSLog
import SwiftData

/// When a background guide refresh may run, given the playlist content syncs
/// around it. Pure so the ordering can be unit-tested; `EPGSyncService` owns
/// the one instance and feeds it.
///
/// Both downloads hit the same provider account, and Xtream panels commonly
/// cap an account at one concurrent connection — a guide download racing the
/// catalog sync gets one of the two rejected (and can leave the account
/// briefly blocked, failing the sync's next requests too). So the gate is fed
/// the real state from the places that own it, rather than predicting which
/// sync is about to start: `MainTabView` reports whether its auto-sync queue
/// holds anything, and `SyncProgressView` — the one place any content sync
/// runs — reports each start and finish.
struct EPGRefreshGate {
    /// Content syncs running right now, automatic or manual.
    private(set) var runningContentSyncs = 0
    /// Whether auto-syncs are queued or on screen in the blocking cover.
    var isAutoSyncQueued = false
    /// A background refresh that was held back or cut short, run as soon as no
    /// content sync is pending. Set by any deferred trigger and by every
    /// successful sync — a freshly synced playlist's channels shouldn't wait
    /// for the next scheduled run.
    private(set) var isRefreshOwed = false

    var isContentSyncPending: Bool {
        runningContentSyncs > 0 || isAutoSyncQueued
    }

    /// A background trigger asking to refresh. Returns whether it may start
    /// now; otherwise the refresh is owed.
    mutating func request() -> Bool {
        isRefreshOwed = isContentSyncPending
        return !isRefreshOwed
    }

    /// A refresh was cut short and has to run again.
    mutating func owe() {
        isRefreshOwed = true
    }

    mutating func contentSyncStarted() {
        runningContentSyncs += 1
    }

    /// Every start is paired with one finish, whether the sync succeeded,
    /// failed or was aborted. A successful refresh only owes guide work when it
    /// actually imported Live TV; a movie-only profile must not fetch an XMLTV
    /// guide it cannot display.
    mutating func contentSyncFinished(succeeded: Bool, refreshedLiveTV: Bool) {
        runningContentSyncs = max(0, runningContentSyncs - 1)
        if succeeded, refreshedLiveTV { isRefreshOwed = true }
    }

    /// Whether an owed refresh may start now. Clears the debt when it does.
    mutating func takeOwedRefresh() -> Bool {
        guard isRefreshOwed, !isContentSyncPending else { return false }
        isRefreshOwed = false
        return true
    }
}

@Observable
final class EPGSyncService {
    static let shared = EPGSyncService()

    private(set) var isSyncing = false
    private(set) var enrichmentReport: EPGEnrichmentReport?
    /// Readers observe this rather than download status. A 304 or failed fetch
    /// does not change the guide; a foreground return reloads local readers.
    private(set) var readRevision: UInt64 = 0
    private(set) var clockMinute = Int(Date().timeIntervalSince1970 / 60)
    @ObservationIgnored private var committedSources: [UUID: UInt64] = [:]
    @ObservationIgnored private var coverageTask: Task<Void, Never>?
    @ObservationIgnored private var coverageChecks: [Set<String>: Date] = [:]

    private var container: ModelContainer?
    private var task: Task<Void, Never>?
    /// Whether `task` is a background refresh, which a starting content sync
    /// cancels — rather than a manual "Sync Now", which the viewer asked for.
    @ObservationIgnored private var isBackgroundRefresh = false
    @ObservationIgnored private var gate = EPGRefreshGate()

    /// Whether the app is in the foreground, set from the scene phase. The
    /// periodic check only runs then.
    @ObservationIgnored var isForeground = true {
        didSet {
            if isForeground, !oldValue {
                coverageChecks = [:]
                clockMinute = Int(Date().timeIntervalSince1970 / 60)
                readRevision &+= 1
            }
        }
    }

    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// Minute ticks refresh now/next locally; network scheduling remains half-hourly.
    static let periodicCheckInterval: Duration = .seconds(60)

    private init() {}

    func configure(container: ModelContainer) {
        if self.container !== container { coverageChecks = [:] }
        self.container = container
        updateCommittedRevision()
    }

    /// Manual trigger (settings "Sync Now"): refreshes now regardless of the
    /// schedule or any in-flight content sync.
    func syncNow() {
        kick(allowConditional: false)
    }

    /// A metadata setting change must not force another full provider download.
    /// Uses the same task lifetime, admission gate and committed-reader reload.
    func refreshEnrichment() {
        guard !ContentIndexingService.shared.isPlaybackActive, gate.request() else { return }
        kick(background: true, metadataOnly: true)
    }

    /// Background trigger: refreshes only if the guide is stale per the EPG
    /// frequency setting — and never alongside a pending playlist sync (see
    /// `EPGRefreshGate`). A deferred refresh runs once the sync is done.
    ///
    /// Called at launch, on every return to the foreground, when the profile
    /// or its areas change, and periodically while the app stays open. Launch
    /// alone wasn't enough: an Apple TV resumes Lume for days without a cold
    /// launch, so the guide ran out of listings and went empty — and a launch
    /// under a profile with Live TV off skipped it with nothing to try again.
    func syncIfDue(reason: String) {
        let providerDue = isDue
        guard providerDue || EPGEnrichmentSettings.isDue() else {
            Logger.database.debug("EPG refresh not due (\(reason, privacy: .public))")
            ensureCoverage(reason: reason)
            return
        }
        guard gate.request() else {
            Logger.database.info("EPG refresh due (\(reason, privacy: .public)) — waiting for a playlist sync")
            return
        }
        Logger.database.info("EPG refresh due (\(reason, privacy: .public))")
        // Daily metadata does not shorten a weekly provider schedule or stamp
        // its last-success date without actually checking that provider.
        kick(background: true, metadataOnly: !providerDue)
    }

    /// Ticks the local clock every minute and re-checks the network schedule
    /// every half-hour while foregrounded — for a TV left on Lume for hours.
    /// Never imports during playback: saves merge into the main context and
    /// hitch the player, which is why indexing pauses then too. The next
    /// check after playback catches up. Idempotent.
    func startPeriodicChecks() {
        guard periodicTask == nil else { return }
        periodicTask = Task(priority: .utility) { [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicCheckInterval)
                guard let self, !Task.isCancelled else { return }
                guard isForeground else { continue }
                clockMinute = Int(Date().timeIntervalSince1970 / 60)
                if !ContentIndexingService.shared.isPlaybackActive,
                   tickCount % 30 == 0
                {
                    syncIfDue(reason: "periodic")
                }
                tickCount += 1
            }
        }
    }

    /// One off-main coverage check at a time. Per-source attempt timestamps
    /// provide backoff even across launches; event channels never trigger it
    /// unless that source previously supplied programmes for them.
    func ensureCoverage(channelIDs: Set<String>? = nil, reason: String = "visible guide") {
        guard let container, coverageTask == nil, task == nil, isForeground,
              !ContentIndexingService.shared.isPlaybackActive,
              AppAreaSettings.isEnabled(.liveTV)
        else { return }
        let scope = channelIDs ?? []
        let now = Date()
        if let previous = coverageChecks[scope], now.timeIntervalSince(previous) >= 0,
           now.timeIntervalSince(previous) < 5 * 60 { return }
        if coverageChecks.count >= 64 { coverageChecks = [:] }
        coverageChecks[scope] = now
        coverageTask = Task(priority: .utility) {
            defer { coverageTask = nil }
            let check = Task.detached(priority: .utility) {
                try EPGCoverage.needsRecovery(container: container, channelIDs: channelIDs)
            }
            do {
                let repair = try await withTaskCancellationHandler { try await check.value } onCancel: { check.cancel() }
                guard repair, !Task.isCancelled, isForeground, task == nil else { return }
                guard gate.request() else { return }
                Logger.database.info("EPG coverage repair (\(reason, privacy: .public))")
                kick(background: true, allowConditional: false)
            } catch {
                Logger.database.warning("EPG coverage check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateCommittedRevision() {
        guard let container else { return }
        do {
            let sources = try ModelContext(container).fetch(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.isEnabled }))
            let generations = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.committedGeneration) })
            if generations != committedSources {
                coverageChecks = [:]
                committedSources = generations
                readRevision &+= 1
            }
        } catch {
            Logger.database.warning("EPG revision read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Content sync reports

    /// `MainTabView`'s auto-sync queue went from empty to busy or back.
    func setAutoSyncQueued(_ queued: Bool) {
        gate.isAutoSyncQueued = queued
        runOwedRefresh()
    }

    /// A playlist content sync is starting. A background refresh already in
    /// flight is cancelled and owed rather than left to race it — the guide may
    /// have started first (at launch, or before the viewer switched to a stale
    /// playlist), and the gate alone only keeps it from starting second.
    func contentSyncDidStart() {
        gate.contentSyncStarted()
        if let task, isBackgroundRefresh {
            task.cancel()
            gate.owe()
        }
    }

    /// The content sync reported by `contentSyncDidStart` ended, however it
    /// ended.
    func contentSyncDidFinish(succeeded: Bool, refreshedLiveTV: Bool = true) {
        gate.contentSyncFinished(succeeded: succeeded, refreshedLiveTV: refreshedLiveTV)
        runOwedRefresh()
    }

    private func runOwedRefresh() {
        // `container` first: taking the debt before `configure` would drop it.
        guard container != nil, task == nil, gate.takeOwedRefresh() else { return }
        kick(background: true)
    }

    private var isDue: Bool {
        // A guide-schema bump (new XMLTV signals to capture) forces one refresh
        // regardless of the frequency, so existing users back-fill the new
        // columns on their next launch. This is also what back-fills the
        // sub-titles the Sports Hub matches on — a guide that still has none
        // after it simply doesn't ship them, and re-downloading it on every
        // hub open wouldn't change that.
        if EPGSyncSchedule.schemaVersion < SyncFrequency.epgCurrentSchemaVersion { return true }
        let raw = UserDefaults.standard.string(forKey: SyncFrequency.epgStorageKey) ?? ""
        let frequency = SyncFrequency.resolveEPG(raw)
        return frequency.isDue(lastSyncDate: EPGSyncSchedule.lastSyncDate)
    }

    private func kick(background: Bool = false, allowConditional: Bool = true, metadataOnly: Bool = false) {
        // Sports availability follows the Live TV switch too.
        guard AppAreaSettings.isEnabled(.liveTV) else {
            Logger.database.info("EPG refresh skipped: guide-consuming areas are switched off")
            return
        }
        guard let container, task == nil else { return }
        isSyncing = true
        isBackgroundRefresh = background
        let manager = EPGSyncManager(modelContainer: container)
        let profileToken = ActiveProfileStore.current?.uuidString ?? ""
        // Background guide refresh: run below the UI so an in-flight sync (which
        // saves into the shared catalog container, churning browse `@Query`s)
        // yields CPU to the main thread instead of competing with it. The
        // profile showed EPG ingest pegging a background thread at 100% in
        // lockstep with a frozen main thread right after a playlist sync.
        task = Task(priority: .utility) {
            var report: EPGEnrichmentReport?
            let outcome = await BackgroundActivity.perform("Guide refresh") {
                if metadataOnly {
                    do {
                        report = try await EPGEnrichmentSync().sync(
                            container: container, enabled: UserDefaults.standard.bool(forKey: EPGEnrichmentSettings.enabledKey), fence: .live
                        )
                        return report?.hasWarning == true ? SyncRefreshOutcome.succeededWithWarnings : .succeeded
                    } catch is CancellationError {
                        return SyncRefreshOutcome.cancelled
                    } catch {
                        Logger.database.warning("EPG enrichment publication failed: \(error.localizedDescription, privacy: .public)")
                        return SyncRefreshOutcome.failed
                    }
                }
                let result = await manager.syncAllSources(
                    allowConditional: allowConditional,
                    enrichProgrammes: UserDefaults.standard.bool(forKey: EPGEnrichmentSettings.enabledKey)
                )
                report = await manager.enrichmentReport
                return result
            }
            if outcome.isSuccessful, !Task.isCancelled, !metadataOnly {
                EPGSyncSchedule.lastSyncDate = Date()
                EPGSyncSchedule.schemaVersion = SyncFrequency.epgCurrentSchemaVersion
            }
            isSyncing = false
            task = nil
            recordEnrichment(report, outcome: outcome, profileToken: profileToken)
            updateCommittedRevision()
            InAppNotifications.shared.report(
                Task.isCancelled ? .cancelled : outcome,
                subject: .guide, startedUnder: profileToken, currentProfileToken: ActiveProfileStore.current?.uuidString ?? "",
                detail: report?.state == .disabled ? nil : report?.message
            )
            Logger.database.info("EPG refresh finished (outcome: \(String(describing: outcome), privacy: .public))")
            // A refresh cancelled for a content sync may wind down after that
            // sync already finished and found this task still set.
            runOwedRefresh()
        }
    }

    private func recordEnrichment(_ report: EPGEnrichmentReport?, outcome: SyncRefreshOutcome, profileToken: String) {
        guard profileToken == (ActiveProfileStore.current?.uuidString ?? "") else { return }
        if outcome == .cancelled, UserDefaults.standard.bool(forKey: EPGEnrichmentSettings.enabledKey) {
            enrichmentReport = EPGEnrichmentReport(state: .interrupted)
        } else if let report {
            enrichmentReport = report
        }
    }
}

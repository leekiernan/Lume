//
//  EPGSyncManager.swift
//  Lume
//
//  The dedicated EPG pipeline, split out of the playlist sync. It stages each
//  enabled source before publishing that source's guide in a single save.
//
//  A channel is guided by exactly one source. Sources are walked oldest-first
//  and each claims the channels it carries; later sources are then confined to
//  the channels still unclaimed. Without that, two sources covering the same
//  channel both survived — the listing id only collapses programmes whose start
//  matches to the second — and the guide drew their schedules on top of each
//  other.
//
//  The downloaded file stays on disk; staging holds one source's deduplicated
//  programmes in memory until it can be published.
//

import Foundation
import OSLog
import SwiftData

actor EPGSyncManager {
    let modelContainer: ModelContainer
    private let client: M3UClient
    private let writeCoordinator: LocalStoreWriteCoordinator

    init(
        modelContainer: ModelContainer,
        client: M3UClient = M3UClient(),
        writeCoordinator: LocalStoreWriteCoordinator = .shared
    ) {
        self.modelContainer = modelContainer
        self.client = client
        self.writeCoordinator = writeCoordinator
    }

    /// Refreshes the guide from every enabled source. Returns `true` only when
    /// every source succeeded, so the global refresh date never hides a failed
    /// source from the next due check.
    @discardableResult
    func syncAllSources() async -> Bool {
        let sources = enabledSources()
        guard !sources.isEmpty else {
            Logger.database.info("No enabled EPG sources, skipping EPG sync")
            return false
        }

        guard let knownChannelIDs = channelIDs() else {
            // Nothing references a guide yet (no live streams synced) — leave any
            // existing listings untouched rather than wiping them for nothing.
            Logger.database.info("No live streams with EPG channel IDs, skipping EPG sync")
            return false
        }

        var everySourceSynced = true
        var unclaimedChannelIDs = knownChannelIDs
        let fence = Fence.live
        for source in sources {
            let result = await sync(source: source, knownChannelIDs: unclaimedChannelIDs, fence: fence)
            unclaimedChannelIDs.subtract(result.claimedChannelIDs)
            everySourceSynced = everySourceSynced && result.didSync
        }
        // Listings created before source-scoped publication have no ownership
        // metadata. Keep that aggregate snapshot whenever any source failed,
        // then retire it only after every enabled source has published (or was
        // safely superseded by an earlier successful source) in this pass.
        // That gives a valid empty guide the same replacement semantics as a
        // non-empty guide without throwing away another source's last snapshot
        // during a partial refresh failure.
        if everySourceSynced {
            do {
                try await retireLegacySnapshot(fence: fence)
            } catch is CancellationError {
                return false
            } catch {
                Logger.database.warning("EPG legacy snapshot retirement failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        return everySourceSynced
    }

    // MARK: - Per-source sync

    /// What one source contributed: whether it synced at all, and which channels
    /// it now owns for the rest of this refresh.
    private struct SourceResult {
        let didSync: Bool
        let claimedChannelIDs: Set<String>
    }

    private nonisolated struct StagedSource {
        let programmes: [ParsedProgramme]
        let parsedProgrammeCount: Int

        var channelIDs: Set<String> {
            Set(programmes.map(\.channelId))
        }
    }

    private nonisolated enum EPGPublicationError: Error {
        case suspiciousEmpty
        case invalidDocument
        case sourceChanged
    }

    private func sync(source: SourceInfo, knownChannelIDs: Set<String>, fence: Fence) async -> SourceResult {
        let interval = Perf.begin(.epgSourceSync)
        defer { Perf.end(interval) }

        markStatus(source.id, .syncing)
        guard !source.url.isEmpty else {
            markStatus(source.id, .error)
            return SourceResult(didSync: false, claimedChannelIDs: [])
        }
        guard !knownChannelIDs.isEmpty else {
            // Every channel this source could guide is already covered by an
            // earlier one. Retire any snapshot this source previously owned,
            // or its old programmes would still overlap the earlier source.
            do {
                try await publish(StagedSource(programmes: [], parsedProgrammeCount: 0), for: source, fence: fence)
                Logger.database.info("EPG source \(source.id, privacy: .public) retired, all channels already guided")
                markSynced(source.id)
                return SourceResult(didSync: true, claimedChannelIDs: [])
            } catch {
                markStatus(source.id, .error)
                return SourceResult(didSync: false, claimedChannelIDs: [])
            }
        }
        for attempt in 0 ... 1 {
            do {
                try Task.checkCancellation()
                let staged = try await stage(source.url, knownChannelIDs: knownChannelIDs)
                // A non-empty XMLTV document that yielded no programmes for the
                // requested channels is a mapping failure, not evidence that a
                // previously committed source snapshot should be erased.
                guard staged.parsedProgrammeCount == 0 || !staged.programmes.isEmpty else {
                    throw EPGPublicationError.suspiciousEmpty
                }
                try await publish(staged, for: source, fence: fence)
                markSynced(source.id)
                return SourceResult(didSync: true, claimedChannelIDs: staged.channelIDs)
            } catch is CancellationError {
                markStatus(source.id, .idle)
                return SourceResult(
                    didSync: false,
                    claimedChannelIDs: retainedChannelIDs(for: source.id, limitedTo: knownChannelIDs)
                )
            } catch {
                guard attempt == 0 else {
                    let nsError = error as NSError
                    let detail = (error as? M3UError)?.logDescription ?? "\(nsError.domain) \(nsError.code)"
                    Logger.database.warning("EPG source \(source.id, privacy: .public) sync failed: \(detail, privacy: .public)")
                    markStatus(source.id, .error)
                    return SourceResult(
                        didSync: false,
                        claimedChannelIDs: retainedChannelIDs(for: source.id, limitedTo: knownChannelIDs)
                    )
                }
                Logger.database.info("EPG source \(source.id, privacy: .public) retrying once after a failed attempt")
            }
        }
        return SourceResult(didSync: false, claimedChannelIDs: [])
    }

    // MARK: - Source / channel lookups

    private nonisolated struct SourceInfo {
        let id: UUID
        let url: String
    }

    private func enabledSources() -> [SourceInfo] {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let descriptor = FetchDescriptor<EPGSource>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.addedAt)]
        )
        let sources = (try? context.fetch(descriptor)) ?? []
        return sources.map { SourceInfo(id: $0.id, url: $0.url) }
    }

    /// The set of EPG channel IDs any live stream references, or nil when there
    /// is nothing to guide (so the sync can be skipped without clearing data).
    private func channelIDs() -> Set<String>? {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<LiveStream>()
        descriptor.propertiesToFetch = [\.epgChannelId]
        let streams = (try? context.fetch(descriptor)) ?? []
        let ids = Set(streams.compactMap(\.epgChannelId))
        return ids.isEmpty ? nil : ids
    }

    /// A failed source retains its last committed snapshot, which must continue
    /// to reserve those channels during this run. Otherwise a later source can
    /// publish the same channel and make the guide non-deterministically overlap.
    private func retainedChannelIDs(for sourceID: UUID, limitedTo knownChannelIDs: Set<String>) -> Set<String> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<EPGListing>(predicate: #Predicate { $0.sourceID == sourceID })
        descriptor.propertiesToFetch = [\.channelId]
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.channelId)).intersection(knownChannelIDs)
    }

    // MARK: - Staging and atomic publication

    /// Fetching and parsing do not mutate SwiftData. An abandoned stage is
    /// therefore cleaned up by normal process teardown and cannot be observed
    /// by guide readers.
    private func stage(_ url: String, knownChannelIDs: Set<String>) async throws -> StagedSource {
        let interval = Perf.begin(.epgIngest)
        defer { Perf.end(interval) }

        let isRemote = !(URL(string: url)?.isFileURL ?? false)
        let fileURL = try await client.downloadEPG(from: url)
        defer { if isRemote { try? FileManager.default.removeItem(at: fileURL) } }

        var programmesByKey: [String: ParsedProgramme] = [:]
        var cancelled = false
        let parseOutcome = XMLTVParser.parse(fileURL: fileURL, batchSize: 2000) { batch in
            if Task.isCancelled { cancelled = true; return }
            for programme in batch where knownChannelIDs.contains(programme.channelId) {
                let key = "\(programme.channelId)\u{1F}\(Int(programme.start.timeIntervalSince1970))"
                guard let current = programmesByKey[key] else {
                    programmesByKey[key] = programme
                    continue
                }
                if Self.contentPrecedes(programme, current) { programmesByKey[key] = programme }
            }
        }
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        guard parseOutcome.succeeded,
              parseOutcome.encounteredProgrammeCount == 0 || parseOutcome.programmeCount > 0
        else { throw EPGPublicationError.invalidDocument }
        return StagedSource(
            programmes: programmesByKey.values.sorted(by: Self.stagingPrecedes),
            parsedProgrammeCount: parseOutcome.programmeCount
        )
    }

    /// The staging order: channel, start, then the dedupe tiebreak. Compares
    /// field by field and stops at the first difference — the sort runs
    /// n·log n comparisons over a full guide (~218k rows), and building a
    /// composite string for both sides of each one dominated staging.
    private nonisolated static func stagingPrecedes(_ lhs: ParsedProgramme, _ rhs: ParsedProgramme) -> Bool {
        if lhs.channelId != rhs.channelId { return lhs.channelId < rhs.channelId }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return contentPrecedes(lhs, rhs)
    }

    /// Which of two programmes sharing a channel and start wins the dedupe:
    /// the earlier end, then title, then description — deterministic, so the
    /// same document always publishes the same snapshot.
    private nonisolated static func contentPrecedes(_ lhs: ParsedProgramme, _ rhs: ParsedProgramme) -> Bool {
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.description < rhs.description
    }

    /// One source gets exactly one durable publication. If validation, a final
    /// cancellation check, or `save()` fails, the context rolls back and that
    /// source's prior committed snapshot remains visible.
    private func publish(_ staged: StagedSource, for sourceInfo: SourceInfo, fence: Fence) async throws {
        let sourceID = sourceInfo.id
        let request = LocalStoreWriteCoordinator.Request(
            scope: .epgPublish(sourceInfo.id),
            mode: .exclusive,
            priority: .background,
            coalescingKey: "epg-publish-\(sourceInfo.id.uuidString)-\(sourceInfo.url)",
            fence: fence
        )
        try await writeCoordinator.withLease(request) { [modelContainer] in
            try Task.checkCancellation()
            guard Fence.live == fence else { throw LocalStoreWriteError.superseded }
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            guard let source = try context.fetch(
                FetchDescriptor<EPGSource>(predicate: #Predicate { $0.id == sourceID })
            ).first, source.isEnabled, source.url == sourceInfo.url else {
                throw EPGPublicationError.sourceChanged
            }
            try Self.replaceSnapshot(staged, for: sourceInfo, source: source, in: context)
            try Task.checkCancellation()
            guard Fence.live == fence else { throw LocalStoreWriteError.superseded }
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private nonisolated static func replaceSnapshot(
        _ staged: StagedSource,
        for sourceInfo: SourceInfo,
        source: EPGSource,
        in context: ModelContext
    ) throws {
        let sourceID: UUID? = sourceInfo.id
        let oldRows = try context.fetch(
            FetchDescriptor<EPGListing>(predicate: #Predicate { $0.sourceID == sourceID })
        )
        // A refresh commonly contains the same programme IDs. Deleting and
        // reinserting those @Attribute(.unique) IDs in one save can make
        // SwiftData upsert/remap temporary identifiers. Update retained rows
        // instead; only truly removed/added IDs are deleted/inserted.
        var oldByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
        // Pre-LUM-13 rows had no source ownership. Retire only the legacy rows
        // for channels this source is now committing; the remaining aggregate
        // snapshot is retired only after every enabled source succeeds below.
        let legacyRows = try context.fetch(
            FetchDescriptor<EPGListing>(predicate: #Predicate { $0.sourceID == nil })
        )
        let stagedChannels = Set(staged.programmes.map(\.channelId))
        for row in legacyRows where stagedChannels.contains(row.channelId) {
            context.delete(row)
        }
        for programme in staged.programmes {
            try Task.checkCancellation()
            let start = Int(programme.start.timeIntervalSince1970)
            let id = "\(sourceInfo.id.uuidString)-\(programme.channelId)-\(start)"
            let category = programme.categories.isEmpty ? nil : programme.categories.joined(separator: ", ")
            if let existing = oldByID.removeValue(forKey: id) {
                existing.update(from: programme, category: category)
            } else {
                context.insert(EPGListing(
                    id: id,
                    channelId: programme.channelId,
                    title: programme.title,
                    listingDescription: programme.description,
                    start: programme.start,
                    end: programme.end,
                    sourceID: sourceInfo.id,
                    subtitle: programme.subtitle,
                    category: category
                ))
            }
        }
        for stale in oldByID.values {
            context.delete(stale)
        }
        source.committedGeneration &+= 1
    }

    /// A pre-LUM-13 guide was one aggregate snapshot, so its unowned rows
    /// cannot be assigned to a single source without guessing. The only safe
    /// migration point is after this pass has source-scoped replacements for
    /// every enabled source. This also clears a valid empty guide's former
    /// legacy rows while a failed source leaves the aggregate fallback intact.
    private func retireLegacySnapshot(fence: Fence) async throws {
        let request = LocalStoreWriteCoordinator.Request(
            scope: .maintenance,
            mode: .exclusive,
            priority: .background,
            coalescingKey: "epg-retire-legacy-snapshot",
            fence: fence
        )
        try await writeCoordinator.withLease(request) { [modelContainer] in
            try Task.checkCancellation()
            guard Fence.live == fence else { throw LocalStoreWriteError.superseded }
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            let legacyRows = try context.fetch(
                FetchDescriptor<EPGListing>(predicate: #Predicate { $0.sourceID == nil })
            )
            for row in legacyRows {
                context.delete(row)
            }
            try Task.checkCancellation()
            guard Fence.live == fence else { throw LocalStoreWriteError.superseded }
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    // MARK: - Status bookkeeping

    private func markStatus(_ sourceID: UUID, _ status: SyncStatus) {
        updateSource(sourceID) { $0.syncStatus = status }
    }

    private func markSynced(_ sourceID: UUID) {
        updateSource(sourceID) {
            $0.syncStatus = .idle
            $0.lastSyncDate = Date()
        }
    }

    private func updateSource(_ sourceID: UUID, _ mutate: (EPGSource) -> Void) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let source = try? context.fetch(
            FetchDescriptor<EPGSource>(predicate: #Predicate { $0.id == sourceID })
        ).first else { return }
        mutate(source)
        try? context.save()
    }

    /// Resets any source left `.syncing` by a process that died mid-refresh.
    /// `.syncing` is runtime-only, so a value observed at launch is stale.
    static func recoverInterruptedSyncs(in context: ModelContext) {
        let syncingRaw = SyncStatus.syncing.rawValue
        let descriptor = FetchDescriptor<EPGSource>(
            predicate: #Predicate { $0.syncStatusRaw == syncingRaw }
        )
        guard let stuck = try? context.fetch(descriptor), !stuck.isEmpty else { return }
        for source in stuck {
            source.syncStatus = .idle
        }
        try? context.save()
    }
}

import Foundation
import OSLog
import SwiftData

/// Optional metadata-only pass, after timetable sources. It reuses the guide
/// downloader, SAX parser and write lease; there is no second guide ownership
/// lane, unbounded programme table or per-card network work.
actor EPGEnrichmentSync {
    static let feedURL = URL(string: "https://epgshare01.online/epgshare01/epg_ripper_US_LOCALS1.xml.gz")!
    private let client: M3UClient
    private let writeCoordinator: LocalStoreWriteCoordinator
    private let cacheURL: URL?
    private let defaults: UserDefaults
    private let feedURL: URL

    init(
        client: M3UClient = M3UClient(),
        writeCoordinator: LocalStoreWriteCoordinator = .shared,
        cacheURL: URL? = EPGEnrichmentCache.defaultURL,
        defaults: UserDefaults = .standard,
        feedURL: URL = EPGEnrichmentSync.feedURL
    ) {
        self.client = client
        self.writeCoordinator = writeCoordinator
        self.cacheURL = cacheURL
        self.defaults = defaults
        self.feedURL = feedURL
    }

    func sync(container: ModelContainer, enabled: Bool, fence: Fence, now: Date = Date()) async throws {
        try Task.checkCancellation()
        var snapshot: EPGEnrichmentCache?
        if enabled {
            let aliases = try Self.aliases(in: ModelContext(container))
            if aliases.isEmpty {
                // Unsupported/event-only catalogs never download the feed.
                defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentSettings.checkedKey)
            } else {
                snapshot = try await load(channelIDs: Set(aliases.keys), now: now)
            }
        }
        try await publish(snapshot, container: container, enabled: enabled, fence: fence, now: now)
    }

    private func load(channelIDs: Set<String>, now: Date) async throws -> EPGEnrichmentCache? {
        let cached = EPGEnrichmentCache.read(from: cacheURL)
        if let cached, cached.isFresh(url: feedURL.absoluteString, channelIDs: channelIDs, now: now) { return cached }
        let lastAttempt = defaults.double(forKey: EPGEnrichmentSettings.attemptedKey)
        let lastCheck = defaults.double(forKey: EPGEnrichmentSettings.checkedKey)
        if lastAttempt > lastCheck, now.timeIntervalSince1970 >= lastAttempt,
           now.timeIntervalSince1970 - lastAttempt < EPGEnrichmentSettings.retryInterval
        {
            return cached.flatMap { $0.isUsable(url: feedURL.absoluteString, now: now) ? $0 : nil }
        }
        defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentSettings.attemptedKey)
        do {
            let canValidate = cached?.isUsable(url: feedURL.absoluteString, now: now) == true && channelIDs.isSubset(of: cached?.channelIDs ?? [])
            let result = try await client.downloadGuide(
                from: feedURL.absoluteString, lastModified: canValidate ? cached?.lastModified : nil, entityTag: canValidate ? cached?.entityTag : nil
            )
            let snapshot: EPGEnrichmentCache
            switch result {
            case .notModified:
                guard var previous = cached, canValidate else { throw EnrichmentError.invalidDocument }
                previous.checkedAt = now
                snapshot = previous
            case let .file(file, lastModified, entityTag):
                defer { if file != feedURL { try? FileManager.default.removeItem(at: file) } }
                snapshot = try parse(file: file, channelIDs: channelIDs, now: now, lastModified: lastModified, entityTag: entityTag)
            }
            try Task.checkCancellation()
            try snapshot.write(to: cacheURL)
            defaults.set(now.timeIntervalSince1970, forKey: EPGEnrichmentSettings.checkedKey)
            Logger.database.info("EPG enrichment cached: \(snapshot.programmes.count) programmes, \(channelIDs.count) verified stations")
            return snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Optional metadata failure never destroys the provider schedule or
            // advances the successful check timestamp. Retain a recent cache;
            // after 48 hours restore provider-only fields instead.
            Logger.database.warning("EPG enrichment unavailable; keeping provider guide: \(error.localizedDescription, privacy: .public)")
            return cached.flatMap { $0.isUsable(url: feedURL.absoluteString, now: now) ? $0 : nil }
        }
    }

    private func parse(
        file: URL, channelIDs: Set<String>, now: Date, lastModified: String?, entityTag: String?
    ) throws -> EPGEnrichmentCache {
        var programmes: [ParsedProgramme] = []
        let end = now.addingTimeInterval(4 * 24 * 3600)
        let start = now.addingTimeInterval(-2 * 3600)
        var exceededLimit = false
        let outcome = XMLTVParser.parse(fileURL: file, channelIDs: channelIDs) { batch in
            for programme in batch where programme.end > start && programme.start < end && programme.end > programme.start {
                guard programmes.count < EPGEnrichmentCache.maximumProgrammes else { exceededLimit = true; continue }
                programmes.append(programme)
            }
        }
        try Task.checkCancellation()
        guard outcome.succeeded, !exceededLimit, programmes.contains(where: { $0.end > now }) else { throw EnrichmentError.invalidDocument }
        return EPGEnrichmentCache(url: feedURL.absoluteString, checkedAt: now, channelIDs: channelIDs, programmes: programmes, lastModified: lastModified, entityTag: entityTag)
    }

    private nonisolated enum EnrichmentError: Error {
        case invalidDocument
    }

    private nonisolated static func aliases(in context: ModelContext) throws -> [String: String] {
        var query = FetchDescriptor<LiveStream>()
        query.propertiesToFetch = [\.name, \.epgChannelId]
        let channels = try context.fetch(query).compactMap { stream -> EPGEnrichmentStations.Channel? in
            guard let id = stream.epgChannelId, !id.isEmpty else { return nil }
            return .init(name: stream.name, epgID: id)
        }
        return EPGEnrichmentStations.aliases(for: channels)
    }

    private func publish(_ snapshot: EPGEnrichmentCache?, container: ModelContainer, enabled: Bool, fence: Fence, now: Date) async throws {
        let expectedURL = feedURL.absoluteString
        let request = LocalStoreWriteCoordinator.Request(
            scope: .maintenance, mode: .exclusive, priority: .background,
            coalescingKey: "epg-enrichment-\(enabled)-\(snapshot?.checkedAt.timeIntervalSince1970 ?? 0)", fence: fence
        )
        try await writeCoordinator.withLease(request) {
            try Task.checkCancellation()
            guard Fence.live == fence else { throw LocalStoreWriteError.superseded }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let aliases = enabled ? try Self.aliases(in: context) : [:]
            // The app may have been suspended between staging and publication.
            // Never bless a now-expired cache merely because it was valid then.
            let usable = snapshot?.isUsable(url: expectedURL, now: max(now, Date())) == true
            let index = EPGProgrammeEnrichment.Index(programmes: usable ? snapshot?.programmes ?? [] : [], aliases: aliases)
            let ids = Array(aliases.values)
            let rows = try context.fetch(FetchDescriptor<EPGListing>(predicate: #Predicate {
                ids.contains($0.channelId) || $0.enrichmentBaseline != nil
            }))
            let sources = try context.fetch(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.isEnabled }))
            let enabledIDs = Set(sources.map(\.id))
            var changedSources: Set<UUID> = []
            var changed = 0
            for row in rows {
                try Task.checkCancellation()
                // Disabled/deleted sources never acquire supplementary data.
                let active = row.sourceID.map { enabledIDs.contains($0) } == true
                if try EPGProgrammeEnrichment.apply(active ? index : .init(), to: row) {
                    changed += 1
                    if let id = row.sourceID { changedSources.insert(id) }
                }
            }
            for source in sources where changedSources.contains(source.id) {
                source.committedGeneration &+= 1
            }
            try Task.checkCancellation()
            guard Fence.live == fence else { throw LocalStoreWriteError.superseded }
            do {
                if context.hasChanges { try context.save() }
            } catch {
                context.rollback()
                throw error
            }
            Logger.database.info("EPG enrichment published: \(changed) programme metadata changes; provider times retained")
        }
    }
}

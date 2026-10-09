import Foundation
import OSLog
import SwiftData

/// Stage bounded metadata sequentially, then publish all feeds together. A
/// refresh of one country must never restore another country's provider fields.
actor EPGEnrichmentSync {
    private let client: M3UClient
    private let writeCoordinator: LocalStoreWriteCoordinator
    private let defaults: UserDefaults
    private let feeds: [EPGEnrichmentFeed]

    init(client: M3UClient = M3UClient(), writeCoordinator: LocalStoreWriteCoordinator = .shared,
         cacheURL: URL? = EPGEnrichmentCache.defaultURL, defaults: UserDefaults = .standard,
         feedURL: URL? = nil, feeds: [EPGEnrichmentFeed]? = nil)
    {
        self.client = client
        self.writeCoordinator = writeCoordinator
        self.defaults = defaults
        self.feeds = feeds ?? feedURL.map { [EPGEnrichmentFeed(id: .usPBS, url: $0, cacheURL: cacheURL)] }
            ?? EPGEnrichmentFeed.production(cacheURL: cacheURL)
    }

    private nonisolated struct Staged {
        let feed: EPGEnrichmentFeed
        let result: EPGEnrichmentFeedLoader.Result
    }

    @discardableResult
    func sync(container: ModelContainer, enabled: Bool, fence: Fence, now: Date = Date()) async throws -> EPGEnrichmentReport {
        try Task.checkCancellation()
        // Cache freshness is not publication success. Retain this debt across
        // cancellation, a stale fence or relaunch between country downloads.
        if enabled { defaults.set(true, forKey: EPGEnrichmentSettings.publicationPendingKey) }
        let scope = enabled ? try EPGEnrichmentScope.load(in: ModelContext(container)) : .init()
        var staged: [Staged] = []
        for feed in feeds {
            try Task.checkCancellation()
            let aliases = scope.aliases(for: feed.id)
            let result: EPGEnrichmentFeedLoader.Result = if enabled, !aliases.isEmpty {
                try await EPGEnrichmentFeedLoader(feed: feed, client: client, defaults: defaults)
                    .load(channelIDs: Set(aliases.keys), now: now)
            } else {
                .init(feed: feed, snapshot: nil, state: enabled ? .unsupported : .disabled)
            }
            staged.append(Staged(feed: feed, result: result))
        }
        let publication = try await publish(staged, container: container, enabled: enabled, fence: fence, now: now)
        defaults.removeObject(forKey: EPGEnrichmentSettings.publicationPendingKey)
        for report in publication.reports {
            if enabled, !report.hasWarning, let id = report.feedID {
                defaults.set((report.checkedAt ?? now).timeIntervalSince1970, forKey: id.checkedKey)
            }
            Logger.database.info("""
            EPG enrichment result [\(report.feedID?.rawValue ?? "unknown", privacy: .public)]: \(report.state.rawValue, privacy: .public); \
            verified stations=\(report.verifiedStations), cached programmes=\(report.cachedProgrammes), \
            exact matches=\(report.matchedProgrammes), changed programmes=\(report.changedProgrammes)
            """)
        }
        var report = EPGEnrichmentReport.combining(publication.reports, enabled: enabled)
        report.changedProgrammes = publication.changed
        return report
    }

    private nonisolated struct Publication {
        let reports: [EPGEnrichmentReport]
        let changed: Int
    }

    private func publish(_ staged: [Staged], container: ModelContainer, enabled: Bool, fence: Fence, now: Date) async throws -> Publication {
        let version = staged.map { "\($0.feed.id.rawValue)-\($0.result.snapshot?.checkedAt.timeIntervalSince1970 ?? 0)" }.joined(separator: "-")
        let request = LocalStoreWriteCoordinator.Request(scope: .maintenance, mode: .exclusive, priority: .background,
                                                         coalescingKey: "epg-enrichment-\(enabled)-\(version)", fence: fence)
        return try await writeCoordinator.withLease(request) {
            try Task.checkCancellation()
            guard Fence.live == fence else { throw LocalStoreWriteError.superseded }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            // Suspension may expire staged data or change enabled categories.
            let publication = try Self.apply(staged, in: context, enabled: enabled, now: max(now, Date()))
            try Task.checkCancellation()
            guard Fence.live == fence else { throw LocalStoreWriteError.superseded }
            do {
                if context.hasChanges { try context.save() }
            } catch {
                context.rollback()
                throw error
            }
            Logger.database.info("EPG enrichment published: \(publication.changed) programme metadata changes; provider times retained")
            return publication
        }
    }

    private nonisolated struct PublicationFeed {
        var report: EPGEnrichmentReport
        let index: EPGProgrammeEnrichment.Index
        let providerIDs: Set<String>
        let eligibleIDs: Set<String>

        init(_ staged: Staged, scope: EPGEnrichmentScope, now: Date) {
            let aliases = scope.aliases(for: staged.feed.id)
            let snapshot = staged.result.snapshot
            let usable = snapshot?.isUsable(url: staged.feed.url.absoluteString, now: now) == true
            index = .init(programmes: usable ? snapshot?.programmes ?? [] : [], aliases: aliases)
            report = staged.result.report
            report.verifiedStations = aliases.count
            providerIDs = EPGEnrichmentStations.providerIDs(for: staged.feed.id)
            eligibleIDs = Set(aliases.values.flatMap(\.self))
        }
    }

    private nonisolated static func apply(_ staged: [Staged], in context: ModelContext, enabled: Bool, now: Date) throws -> Publication {
        let scope = enabled ? try EPGEnrichmentScope.load(in: context) : .init()
        var feeds = staged.map { PublicationFeed($0, scope: scope, now: now) }
        let index = EPGProgrammeEnrichment.Index(merging: feeds.map(\.index))
        let ids = Array(feeds.reduce(into: Set<String>()) { $0.formUnion($1.eligibleIDs) })
        let rows = try context.fetch(FetchDescriptor<EPGListing>(predicate: #Predicate {
            ids.contains($0.channelId) || $0.enrichmentBaseline != nil
        }))
        let sources = try context.fetch(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.isEnabled }))
        let enabledIDs = Set(sources.map(\.id))
        var changedSources: Set<UUID> = []
        var changed = 0
        for row in rows {
            try Task.checkCancellation()
            let active = row.sourceID.map { enabledIDs.contains($0) } == true
            let matched = active && index.metadata(channelID: row.channelId, start: row.start, end: row.end, title: row.title) != nil
            let edited = try EPGProgrammeEnrichment.apply(active ? index : .init(), to: row)
            if edited {
                changed += 1
                if let id = row.sourceID { changedSources.insert(id) }
            }
            for offset in feeds.indices {
                if matched, feeds[offset].index.metadata(channelID: row.channelId, start: row.start, end: row.end, title: row.title) != nil {
                    feeds[offset].report.matchedProgrammes += 1
                }
                if edited, feeds[offset].providerIDs.contains(row.channelId) { feeds[offset].report.changedProgrammes += 1 }
            }
        }
        for source in sources where changedSources.contains(source.id) {
            source.committedGeneration &+= 1
        }
        return Publication(reports: feeds.map(\.report), changed: changed)
    }
}

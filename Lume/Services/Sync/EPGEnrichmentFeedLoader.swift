import Foundation
import OSLog

/// One feed's temporary file is released before the next feed is admitted.
/// Only bounded, selected metadata snapshots survive the sequential load.
nonisolated struct EPGEnrichmentFeedLoader {
    private static let maximumXMLBytes = 768 * 1024 * 1024
    private static let storageReserve = 128 * 1024 * 1024
    let feed: EPGEnrichmentFeed
    let client: M3UClient
    let defaults: UserDefaults

    struct Result {
        let snapshot: EPGEnrichmentCache?
        var report: EPGEnrichmentReport

        init(feed: EPGEnrichmentFeed, snapshot: EPGEnrichmentCache?, state: EPGEnrichmentReport.State, retryAt: Date? = nil) {
            self.snapshot = snapshot
            report = EPGEnrichmentReport(state: state, cachedProgrammes: snapshot?.programmes.count ?? 0,
                                         checkedAt: snapshot?.checkedAt, retryAt: retryAt, feedID: feed.id)
        }
    }

    func load(channelIDs: Set<String>, now: Date) async throws -> Result {
        let cached = EPGEnrichmentCache.read(from: feed.cacheURL)
        if let cached, cached.isFresh(url: feed.url.absoluteString, channelIDs: channelIDs, now: now, refreshInterval: feed.id.refreshInterval) {
            return Result(feed: feed, snapshot: cached, state: .cached)
        }
        let usable = cached.flatMap { $0.isUsable(url: feed.url.absoluteString, now: now) ? $0 : nil }
        let lastFailure = defaults.double(forKey: feed.id.failedKey)
        if lastFailure > 0, now.timeIntervalSince1970 >= lastFailure,
           now.timeIntervalSince1970 - lastFailure < EPGEnrichmentSettings.retryInterval
        {
            return Result(feed: feed, snapshot: usable, state: .deferred, retryAt: Date(timeIntervalSince1970: lastFailure + EPGEnrichmentSettings.retryInterval))
        }
        do {
            let result = try await download(cached: cached, channelIDs: channelIDs, now: now)
            try Task.checkCancellation()
            try result.snapshot?.write(to: feed.cacheURL)
            defaults.removeObject(forKey: feed.id.failedKey)
            Logger.database.info("EPG enrichment cached [\(feed.id.rawValue, privacy: .public)]: \(result.report.cachedProgrammes) programmes, \(channelIDs.count) verified stations")
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            defaults.set(now.timeIntervalSince1970, forKey: feed.id.failedKey)
            Logger.database.warning("EPG enrichment unavailable [\(feed.id.rawValue, privacy: .public)]; keeping provider guide: \(error.localizedDescription, privacy: .public)")
            return Result(feed: feed, snapshot: usable, state: .unavailable, retryAt: now.addingTimeInterval(EPGEnrichmentSettings.retryInterval))
        }
    }

    private func download(cached: EPGEnrichmentCache?, channelIDs: Set<String>, now: Date) async throws -> Result {
        try Self.checkStorage()
        let canValidate = cached?.isUsable(url: feed.url.absoluteString, now: now) == true && channelIDs.isSubset(of: cached?.channelIDs ?? [])
        let result = try await client.downloadGuide(from: feed.url.absoluteString,
                                                    lastModified: canValidate ? cached?.lastModified : nil,
                                                    entityTag: canValidate ? cached?.entityTag : nil, maximumBytes: Self.maximumXMLBytes)
        switch result {
        case .notModified:
            guard var previous = cached, canValidate else { throw LoadError.invalidDocument }
            previous.checkedAt = now
            return Result(feed: feed, snapshot: previous, state: .unchanged)
        case let .file(file, lastModified, entityTag):
            defer { if file != feed.url { try? FileManager.default.removeItem(at: file) } }
            let snapshot = try parse(file: file, channelIDs: channelIDs, now: now, lastModified: lastModified, entityTag: entityTag)
            return Result(feed: feed, snapshot: snapshot, state: .downloaded)
        }
    }

    private func parse(file: URL, channelIDs: Set<String>, now: Date, lastModified: String?, entityTag: String?) throws -> EPGEnrichmentCache {
        var programmes: [ParsedProgramme] = []
        let end = now.addingTimeInterval(4 * 24 * 3600)
        let start = now.addingTimeInterval(-2 * 3600)
        var trimmed = false
        let outcome = XMLTVParser.parse(fileURL: file, channelIDs: channelIDs) { batch in
            for programme in batch where programme.end > start && programme.start < end && programme.end > programme.start {
                programmes.append(programme)
                // Bound memory while parsing; the nearest programmes always survive.
                if programmes.count >= 2 * EPGEnrichmentCache.maximumProgrammes {
                    Self.keepNearest(&programmes)
                    trimmed = true
                }
            }
        }
        try Task.checkCancellation()
        if programmes.count > EPGEnrichmentCache.maximumProgrammes {
            Self.keepNearest(&programmes)
            trimmed = true
        }
        if trimmed {
            // A large selection is a valid document, not a failure: rejecting it
            // would re-download the whole feed on every hourly retry.
            Logger.database.notice("EPG enrichment [\(feed.id.rawValue, privacy: .public)] kept the nearest \(programmes.count) programmes of a larger selection")
        }
        guard outcome.succeeded, programmes.contains(where: { $0.end > now }) else { throw LoadError.invalidDocument }
        return EPGEnrichmentCache(url: feed.url.absoluteString, checkedAt: now, channelIDs: channelIDs, programmes: programmes, lastModified: lastModified, entityTag: entityTag)
    }

    /// Keeps the cache's bound of programmes starting soonest: the window
    /// begins two hours back, so these are the ones a guide shows first.
    static func keepNearest(_ programmes: inout [ParsedProgramme]) {
        guard programmes.count > EPGEnrichmentCache.maximumProgrammes else { return }
        programmes.sort { $0.start < $1.start }
        programmes.removeSubrange(EPGEnrichmentCache.maximumProgrammes...)
    }

    private enum LoadError: Error { case invalidDocument, insufficientStorage }

    private static func checkStorage() throws {
        let capacity = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        if let capacity, capacity < maximumXMLBytes + storageReserve {
            Logger.database.notice("EPG enrichment deferred: insufficient temporary storage; provider guide retained")
            throw LoadError.insufficientStorage
        }
    }
}

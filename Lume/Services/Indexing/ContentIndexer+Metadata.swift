import Foundation
import SwiftData

extension ContentIndexer {
    struct PendingItem {
        let kind: LumeMetadataKind
        let id: String
        let title: String
        let year: Int?
        let existingTMDBId: Int?
        let needsEnrichment: Bool
        let source: LumeProxySource?
    }

    struct IndexResult {
        let item: PendingItem
        let resolvedTMDBId: Int?
        let details: TMDBTitleDetails?
        let usedNetwork: Bool
    }

    private struct BatchKey: Hashable {
        let source: LumeProxySource
        let kind: LumeMetadataKind
    }

    enum PrefetchedMetadata {
        case details(TMDBTitleDetails)
        case pending
    }

    struct PendingMetadataKey: Hashable {
        let sourceIdentity: String
        let kind: LumeMetadataKind
        let language: String
        let tmdbID: Int
    }

    /// One bounded read per source/kind, split further only for an advertised
    /// smaller limit. The proxy is optional: outages and misses retain main's
    /// paced device path. Pending work gets at most one minute to finish first.
    func prefetchMetadata(_ items: [PendingItem], client: LumeMetadataClient = .background, now: Date = Date()) async throws -> [String: PrefetchedMetadata] {
        pendingMetadataSince = pendingMetadataSince.filter { now >= $0.value && now.timeIntervalSince($0.value) < 300 }
        var groups: [BatchKey: [PendingItem]] = [:]
        for item in items where item.needsEnrichment && item.existingTMDBId != nil {
            if let source = item.source { groups[BatchKey(source: source, kind: item.kind), default: []].append(item) }
        }
        var prefetched: [String: PrefetchedMetadata] = [:]
        for (key, items) in groups {
            try Task.checkCancellation()
            let result = try await client.fetch(source: key.source, type: key.kind, ids: items.compactMap(\.existingTMDBId), language: tmdbClient.language, now: now)
            switch result {
            case .unsupported, .unavailable: continue
            case let .available(details, statuses):
                for item in items {
                    if let id = item.existingTMDBId,
                       let value = prefetchedMetadata(id: id, details: details, status: statuses[id], batch: key, now: now)
                    {
                        prefetched[item.id] = value
                    }
                }
            }
        }
        return prefetched
    }

    private func prefetchedMetadata(id: Int, details: [Int: TMDBTitleDetails], status: LumeMetadataItemStatus?,
                                    batch: BatchKey, now: Date) -> PrefetchedMetadata?
    {
        let key = PendingMetadataKey(sourceIdentity: batch.source.identity, kind: batch.kind, language: tmdbClient.language, tmdbID: id)
        guard status == .pending else {
            pendingMetadataSince.removeValue(forKey: key)
            return details[id].map(PrefetchedMetadata.details)
        }
        let started = pendingMetadataSince[key] ?? now
        pendingMetadataSince[key] = started
        return now.timeIntervalSince(started) < 60 ? .pending : nil
    }

    /// Network phase works solely on snapshots. Proxy data works without a
    /// device token, while unresolved IDs retain the existing search policy.
    func resolve(_ item: PendingItem, prefetched: PrefetchedMetadata?) async throws -> IndexResult {
        switch prefetched {
        case let .details(details):
            return IndexResult(item: item, resolvedTMDBId: item.existingTMDBId, details: details, usedNetwork: false)
        case .pending: throw LumeMetadataError.pending
        case nil: break
        }
        guard tmdbClient.isConfigured else {
            return IndexResult(item: item, resolvedTMDBId: item.existingTMDBId, details: nil, usedNetwork: false)
        }
        var usedNetwork = false
        var tmdbId = item.existingTMDBId
        if tmdbId == nil {
            usedNetwork = true
            tmdbId = try await skippingPermanentFailures {
                switch item.kind {
                case .movie: try await self.searchMovieID(query: item.title, year: item.year)
                case .series: try await self.searchTVID(query: item.title, year: item.year)
                }
            }
        }
        var details: TMDBTitleDetails?
        if item.needsEnrichment, let tmdbId {
            usedNetwork = true
            details = try await skippingPermanentFailures {
                try await LumeTitleMetadataRouter(tmdb: self.tmdbClient).deviceDetails(id: tmdbId, type: item.kind)
            }
        }
        return IndexResult(item: item, resolvedTMDBId: tmdbId, details: details, usedNetwork: usedNetwork)
    }

    /// Revalidate after network/busy waits. A changed account or identity must
    /// not acquire the old request's data or completion marker.
    func canApply(_ result: IndexResult, to title: some EnrichedTitle, in context: ModelContext) -> Bool {
        if let current = title.tmdbId, current != result.resolvedTMDBId { return false }
        guard let source = result.item.source else { return true }
        return LumeProxySource.snapshot(contentID: title.id, in: context)?.identity == source.identity
    }
}

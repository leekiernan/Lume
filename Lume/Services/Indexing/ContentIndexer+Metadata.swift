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

    /// One bounded read per source/kind, split further only for an advertised
    /// smaller limit. Whole-batch outages defer the chunk, not fifty device
    /// lookups. Successful partial responses retain per-title paced fallback.
    func prefetchMetadata(_ items: [PendingItem], client: LumeMetadataClient = .background) async throws -> [String: TMDBTitleDetails] {
        var groups: [BatchKey: [PendingItem]] = [:]
        for item in items where item.needsEnrichment && item.existingTMDBId != nil {
            if let source = item.source { groups[BatchKey(source: source, kind: item.kind), default: []].append(item) }
        }
        var prefetched: [String: TMDBTitleDetails] = [:]
        for (key, items) in groups {
            try Task.checkCancellation()
            let result = try await client.fetch(source: key.source, type: key.kind, ids: items.compactMap(\.existingTMDBId), language: tmdbClient.language)
            switch result {
            case .unsupported: continue
            case .unavailable: throw LumeMetadataError.unavailable
            case let .available(details):
                for item in items {
                    if let id = item.existingTMDBId, let value = details[id] { prefetched[item.id] = value }
                }
            }
        }
        return prefetched
    }

    /// Network phase works solely on snapshots. Proxy data works without a
    /// device token, while unresolved IDs retain the existing search policy.
    func resolve(_ item: PendingItem, prefetched: TMDBTitleDetails?) async throws -> IndexResult {
        if let prefetched {
            return IndexResult(item: item, resolvedTMDBId: item.existingTMDBId, details: prefetched, usedNetwork: false)
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

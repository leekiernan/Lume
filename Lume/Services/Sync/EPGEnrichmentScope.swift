import Foundation
import SwiftData

nonisolated struct EPGEnrichmentScope {
    var channels: [EPGEnrichmentStations.Channel] = []
    var eligible: Set<String> = []

    func aliases(for feed: EPGEnrichmentFeed.Identifier) -> [String: String] {
        // Verify against ALL references before filtering enabled categories:
        // hiding a conflicting identity must never make its shared ID safe.
        EPGEnrichmentStations.aliases(for: channels, feed: feed).filter { eligible.contains($0.value) }
    }

    static func load(in context: ModelContext) throws -> Self {
        var query = FetchDescriptor<LiveStream>()
        query.propertiesToFetch = [\.name, \.epgChannelId, \.isHidden, \.categoryId]
        let streams = try context.fetch(query)
        let channels = streams.compactMap { stream -> EPGEnrichmentStations.Channel? in
            guard let id = stream.epgChannelId, !id.isEmpty else { return nil }
            return .init(name: stream.name, epgID: id)
        }
        let live = "live"
        var categories = FetchDescriptor<Category>(predicate: #Predicate { $0.typeRaw == live && $0.isHidden })
        categories.propertiesToFetch = [\.id]
        let hidden = try Set(context.fetch(categories).map(\.id))
        let eligible = Set(streams.compactMap { stream -> String? in
            guard !stream.isHidden, !hidden.contains(stream.categoryId ?? "") else { return nil }
            return stream.epgChannelId
        })
        return Self(channels: channels, eligible: eligible)
    }
}

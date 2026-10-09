import Foundation
import SwiftData

/// Recovery is separate from refresh frequency. A valid empty/event-only feed
/// is not a broken store, and genuinely missing listings are not retried on
/// every minute tick or every remote press.
nonisolated enum EPGCoverage {
    static let retryInterval: TimeInterval = 30 * 60

    static func mayRepair(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let age = now.timeIntervalSince(lastAttempt)
        return age < 0 || age >= retryInterval
    }

    static func needsRecovery(container: ModelContainer, channelIDs: Set<String>? = nil, now: Date = Date()) throws -> Bool {
        let context = ModelContext(container)
        let sources = try context.fetch(FetchDescriptor<EPGSource>(predicate: #Predicate { $0.isEnabled }))
        guard sources.contains(where: { mayRepair(lastAttempt: $0.lastAttemptDate, now: now) }) else { return false }
        var streamQuery = FetchDescriptor<LiveStream>()
        if let channelIDs {
            let ids: [String?] = channelIDs.map { Optional($0) }
            streamQuery.predicate = #Predicate { ids.contains($0.epgChannelId) }
        }
        streamQuery.propertiesToFetch = [\.epgChannelId]
        let referenced = try Set(context.fetch(streamQuery).compactMap(\.epgChannelId).filter { !$0.isEmpty })
        guard !referenced.isEmpty else { return false }
        let registered = Set(sources.flatMap(\.snapshotReferenceIDs))
        for source in sources where mayRepair(lastAttempt: source.lastAttemptDate, now: now) {
            if source.committedGeneration == 0 || !referenced.isSubset(of: registered) { return true }
            let expected = Set(source.snapshotChannelIDs).intersection(channelIDs ?? referenced).intersection(referenced)
            guard source.snapshotProgrammeCount > 0, !expected.isEmpty else { continue }
            let ids = Array(expected)
            let sourceID: UUID? = source.id
            let end = now.addingTimeInterval(ChannelEPGLoader.horizon)
            var query = FetchDescriptor<EPGListing>(predicate: #Predicate {
                $0.sourceID == sourceID && ids.contains($0.channelId) && $0.end > now && $0.start < end
            })
            query.propertiesToFetch = [\.channelId]
            if channelIDs == nil { query.fetchLimit = 1 }
            let available = try Set(context.fetch(query).map(\.channelId))
            if available.isEmpty || (channelIDs != nil && !expected.isSubset(of: available)) { return true }
        }
        return false
    }

    static func canValidate(_ source: EPGSource, referenceIDs: Set<String>, in context: ModelContext, now: Date = Date()) throws -> Bool {
        guard source.validatorURL == source.url, source.committedGeneration > 0,
              source.snapshotProgrammeCount > 0, Set(source.snapshotReferenceIDs) == referenceIDs,
              let end = source.snapshotEnd, end > now,
              source.snapshotSchemaVersion >= SyncFrequency.epgCurrentSchemaVersion
        else { return false }
        let sourceID: UUID? = source.id
        let query = FetchDescriptor<EPGListing>(predicate: #Predicate { $0.sourceID == sourceID })
        return try context.fetchCount(query) == source.snapshotProgrammeCount
    }
}

import Foundation
import OSLog
import SwiftData

nonisolated struct LiveTVHubSnapshot {
    var collections: [LiveTVChannelCollections.Collection] = []
    var epg: [String: ChannelEPG] = [:]
    var programmes: [LiveTVHubProgramme] = []
}

nonisolated enum LiveTVHubLoader {
    static func channels(container: ModelContainer, prefix: String, restriction: ContentRestriction) throws -> [LiveTVHubChannel] {
        guard !prefix.isEmpty else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.id.starts(with: prefix) && !$0.isHidden },
            sortBy: [SortDescriptor(\.num), SortDescriptor(\.name), SortDescriptor(\.id)]
        )
        var result: [LiveTVHubChannel] = []
        try context.enumerate(descriptor, batchSize: 500) { stream in
            try Task.checkCancellation()
            guard !restriction.hides(categoryID: stream.categoryId) else { return }
            result.append(LiveTVHubChannel(id: stream.id, name: stream.name, logoURL: stream.streamIcon,
                                           epgID: stream.epgChannelId, isFavorite: stream.isFavorite,
                                           catchupDays: stream.supportsCatchup ? stream.catchupArchiveDays : 0))
        }
        return result
    }

    /// One time-window pass per guide generation/hour, with bounded row batches
    /// and O(1) title lookup. No all-guide @Query, per-row network request, sort
    /// of every programme, or recurring work at progress-timer frequency.
    static func discover(
        container: ModelContainer, channels: [LiveTVHubChannel], titles: [TMDBListEntry], now: Date
    ) throws -> [LiveTVHubProgramme] {
        guard !channels.isEmpty, !titles.isEmpty else { return [] }
        let index = LiveTVTitleIndex(titles: titles)
        var byEPG: [String: LiveTVHubChannel] = [:]
        for channel in channels {
            guard let id = channel.epgID, !id.isEmpty else { continue }
            if byEPG[id] == nil || (channel.isFavorite && byEPG[id]?.isFavorite == false) { byEPG[id] = channel }
        }
        let upper = now.addingTimeInterval(LiveTVHubPolicy.horizon)
        let lower = now.addingTimeInterval(-LiveTVHubPolicy.horizon)
        var descriptor = FetchDescriptor<EPGListing>(predicate: #Predicate {
            $0.start >= lower && $0.start < upper && $0.end > now
        })
        descriptor.propertiesToFetch = [\.id, \.channelId, \.title, \.start, \.end, \.category, \.releaseYear, \.artworkURL]
        let context = ModelContext(container)
        var selection = LiveTVHubAiringSelection()
        var checked = 0
        try context.enumerate(descriptor, batchSize: 500) { listing in
            try Task.checkCancellation()
            checked += 1
            guard let channel = byEPG[listing.channelId],
                  let match = index.match(title: listing.title, year: listing.releaseYear, category: listing.category) else { return }
            let candidate = "\(match.title.mediaType)-\(match.title.id)"
            let programme = LiveTVHubProgramme(
                id: listing.id, channel: channel, title: listing.title, start: listing.start, end: listing.end,
                artworkURL: listing.artworkURL ?? TMDBClient.backdropURL(match.title.backdropPath)?.absoluteString,
                overview: match.title.overview ?? "", candidateID: candidate, rank: match.rank
            )
            selection.offer(programme, now: now)
        }
        let programmes = selection.programmes
        Logger.database.info("live hub: checked \(checked) window listings against \(titles.count) candidates; \(programmes.count) airings matched")
        return programmes
    }
}

@MainActor @Observable
final class LiveTVHubFeed {
    nonisolated struct Key: Hashable {
        let prefix: String
        let visibility: String
        let profile: String
        let syncedAt: Date?
        let guideIsSyncing: Bool
        let isActive: Bool
        let hour: Int
        let personalIDs: [String]
    }

    private(set) var snapshot = LiveTVHubSnapshot()
    private(set) var isLoading = false
    private var scope: String?
    private var request = RequestToken()
    private var epgRequest = RequestToken()

    func snapshot(prefix: String, visibility: String, profile: String) -> LiveTVHubSnapshot {
        scope == "\(prefix)-\(visibility)-\(profile)" ? snapshot : LiveTVHubSnapshot()
    }

    func refreshEPG(channelIDs: [String], container: ModelContainer, prefix: String, visibility: String, profile: String) async {
        let token = RequestToken()
        epgRequest = token
        let expectedScope = "\(prefix)-\(visibility)-\(profile)"
        let task = Task.detached(priority: .utility) {
            ChannelEPGLoader.load(container: container, channelIds: channelIDs, now: .now)
        }
        let epg = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard epgRequest == token, scope == expectedScope, !Task.isCancelled else { return }
        snapshot.epg = epg
    }

    func load(key: Key, restriction: ContentRestriction, container: ModelContainer, now: Date) async {
        let token = RequestToken()
        request = token
        isLoading = false
        let scope = "\(key.prefix)-\(key.visibility)-\(key.profile)"
        if self.scope != scope { snapshot = LiveTVHubSnapshot() }
        self.scope = scope
        guard !key.guideIsSyncing else { return }
        isLoading = true
        defer { if request == token { isLoading = false } }
        do {
            let initialTask = Task.detached(priority: .utility) {
                let channels = try LiveTVHubLoader.channels(container: container, prefix: key.prefix, restriction: restriction)
                let collections = LiveTVChannelCollections.resolve(channels)
                let wanted = Set(key.personalIDs + collections.flatMap { $0.channels.map(\.id) })
                let epgIDs = channels.filter { wanted.contains($0.id) }.compactMap(\.epgID)
                let epg = ChannelEPGLoader.load(container: container, channelIds: Array(Set(epgIDs)), now: now)
                return (channels, LiveTVHubSnapshot(collections: collections, epg: epg))
            }
            let initial = try await withTaskCancellationHandler { try await initialTask.value } onCancel: { initialTask.cancel() }
            guard request == token, !Task.isCancelled else { return }
            // Keep discovery during a same-scope refresh; personal rails don't
            // wait for network, and a transient list failure won't erase them.
            snapshot.collections = initial.1.collections
            snapshot.epg = initial.1.epg
            let titles = try await LiveTVDiscoveryTitles.shared.titles()
            guard request == token, !Task.isCancelled else { return }
            let discoveryTask = Task.detached(priority: .utility) {
                try LiveTVHubLoader.discover(container: container, channels: initial.0, titles: titles, now: now)
            }
            let programmes = try await withTaskCancellationHandler { try await discoveryTask.value } onCancel: { discoveryTask.cancel() }
            guard request == token, !Task.isCancelled else { return }
            snapshot.programmes = programmes
        } catch {
            guard request == token, !Task.isCancelled else { return }
            Logger.database.error("live hub discovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

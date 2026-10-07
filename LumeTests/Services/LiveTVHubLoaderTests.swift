import Foundation
@testable import Lume
import SwiftData
import Testing

struct LiveTVHubLoaderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: LiveStream.self, EPGListing.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @Test func `hub only resolves visible active playlist channels`() async throws {
        let container = try container()
        let context = ModelContext(container)
        for (id, category, hidden) in [("active-live-1", "allowed", false), ("active-live-2", "locked", false),
                                       ("active-live-3", "allowed", true), ("other-live-4", "allowed", false)]
        {
            let stream = LiveStream(id: id, streamId: 1, name: id, categoryId: category)
            stream.isHidden = hidden
            context.insert(stream)
        }
        try context.save()
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["locked"])
        let channels = try await Task.detached {
            try LiveTVHubLoader.channels(container: container, prefix: "active-", restriction: restriction)
        }.value
        #expect(channels.map(\.id) == ["active-live-1"])
    }

    @Test func `discovery is window bound channel bound and uses guide artwork before TMDB`() async throws {
        let container = try container()
        let context = ModelContext(container)
        let now = now
        for (id, channel, start, end, image) in [
            ("live", "one", -60.0, 60.0, "https://example.com/guide.jpg" as String?),
            ("next", "one", 60.0, 120.0, nil), ("expired", "one", -120.0, 0.0, nil),
            ("far-future", "one", 86400.0, 86500.0, nil), ("other-channel", "other", -60.0, 60.0, nil)
        ] {
            context.insert(EPGListing(id: id, channelId: channel, title: "The Office", listingDescription: "",
                                      start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), artworkURL: image))
        }
        try context.save()
        let channels = [LiveTVHubChannel(id: "active-live-1", name: "One", logoURL: nil, epgID: "one", isFavorite: true)]
        let titles = [TMDBListEntry(id: 2316, mediaType: .series, title: "The Office", backdropPath: "/wide.jpg")]
        let matches = try await Task.detached {
            try LiveTVHubLoader.discover(container: container, channels: channels, titles: titles, now: now)
        }.value
        #expect(Set(matches.map(\.id)) == ["live", "next"])
        #expect(matches.first { $0.id == "live" }?.artworkURL == "https://example.com/guide.jpg")
        #expect(matches.first { $0.id == "next" }?.artworkURL == TMDBClient.backdropURL("/wide.jpg")?.absoluteString)
    }
}

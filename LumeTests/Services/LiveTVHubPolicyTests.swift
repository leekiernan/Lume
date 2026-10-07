import Foundation
@testable import Lume
import Testing

struct LiveTVHubPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func title(_ id: Int, _ name: String, kind: HomeListEntry.MediaType = .series,
                       original: String? = nil, year: String? = nil) -> TMDBListEntry
    {
        TMDBListEntry(id: id, mediaType: kind, title: name, originalTitle: original, releaseYear: year)
    }

    private func channel(_ id: String, name: String = "Channel", epgID: String? = nil, favorite: Bool = false) -> LiveTVHubChannel {
        LiveTVHubChannel(id: id, name: name, logoURL: nil, epgID: epgID, isFavorite: favorite)
    }

    private func airing(_ id: String, start: TimeInterval, end: TimeInterval, candidate: String = "series-1",
                        rank: Int = 0, favorite: Bool = false) -> LiveTVHubProgramme
    {
        LiveTVHubProgramme(id: id, channel: channel(id, favorite: favorite), title: "Programme",
                           start: now.addingTimeInterval(start), end: now.addingTimeInterval(end), artworkURL: nil,
                           overview: "", candidateID: candidate, rank: rank)
    }

    @Test func `matches localized and original titles without fuzzy substrings`() {
        let index = LiveTVTitleIndex(titles: [title(1, "Le Bureau", original: "The Bureau"), title(2, "Élite")])
        #expect(index.match(title: "THE BUREAU", year: nil, category: nil)?.title.id == 1)
        #expect(index.match(title: "Elite", year: nil, category: nil)?.title.id == 2)
        #expect(index.match(title: "Bureau", year: nil, category: nil) == nil)
        #expect(index.match(title: "The Bureau: Episode 2", year: nil, category: nil)?.title.id == 1)
        #expect(index.match(title: "The Bureau: Episode 2", year: nil, category: "Movie") == nil)
    }

    @Test func `remakes and mixed media require disambiguation`() {
        let index = LiveTVTitleIndex(titles: [title(1, "Dune", kind: .movie, year: "1984"),
                                              title(2, "Dune", kind: .movie, year: "2021"), title(3, "Dune")])
        #expect(index.match(title: "Dune", year: nil, category: nil) == nil)
        #expect(index.match(title: "Dune", year: "2021", category: "Film")?.title.id == 2)
        #expect(index.match(title: "Dune (1984)", year: nil, category: "Movie")?.title.id == 1)
        #expect(index.match(title: "Dune", year: "1999", category: "Movie") == nil)
    }

    @Test func `short titles need a year and series episode years are not premiere years`() {
        let index = LiveTVTitleIndex(titles: [title(1, "Up", kind: .movie, year: "2009"), title(2, "The Office", year: "2005")])
        #expect(index.match(title: "Up", year: nil, category: "Movie") == nil)
        #expect(index.match(title: "Up", year: "2009", category: "Movie")?.title.id == 1)
        #expect(index.match(title: "The Office", year: "2010", category: "Series")?.title.id == 2)
    }

    @Test func `local clock rollover expires current and promotes upcoming`() {
        let current = airing("current", start: -60, end: 60)
        let next = airing("next", start: 60, end: 120)
        #expect(LiveTVHubPolicy.discovery([current, next], now: now, liveOnly: true).map(\.id) == ["current"])
        #expect(LiveTVHubPolicy.discovery([current, next], now: now, liveOnly: false).map(\.id) == ["next"])
        #expect(LiveTVHubPolicy.discovery([current, next], now: now.addingTimeInterval(60), liveOnly: true).map(\.id) == ["next"])
        #expect(LiveTVHubPolicy.discovery([current, next], now: now.addingTimeInterval(120), liveOnly: true).isEmpty)
        #expect(current.progress(at: now) == 0.5)
        #expect(current.progress(at: now.addingTimeInterval(-1000)) == 0)
        #expect(current.progress(at: now.addingTimeInterval(1000)) == 1)
    }

    @Test func `rails are bounded deduplicated and ordered for their purpose`() {
        let programmes = (0 ..< 40).map { index in
            airing("\(index)", start: -60, end: 60, candidate: "series-\(index)", rank: 40 - index)
        }
        let live = LiveTVHubPolicy.discovery(programmes, now: now, liveOnly: true)
        #expect(live.count == 20)
        #expect(live.first?.id == "39")
        let duplicate = airing("other-channel", start: -60, end: 60, candidate: "series-39", rank: 100)
        #expect(LiveTVHubPolicy.discovery(programmes + [duplicate], now: now, liveOnly: true).map(\.candidateID) == live.map(\.candidateID))
        let later = airing("later", start: 300, end: 500, candidate: "series-2", rank: 0)
        let sooner = airing("sooner", start: 60, end: 120, rank: 100)
        #expect(LiveTVHubPolicy.discovery([later, sooner], now: now, liveOnly: false).map(\.id) == ["sooner", "later"])
    }

    @Test func `airing reservoir keeps later episodes instead of duplicate channel versions`() {
        var selection = LiveTVHubAiringSelection()
        for index in (1 ... 20).reversed() {
            selection.offer(airing("episode-\(index)", start: Double(index) * 60, end: Double(index + 1) * 60), now: now)
        }
        selection.offer(airing("favorite", start: 60, end: 120, favorite: true), now: now)
        selection.offer(airing("expired", start: -120, end: 0), now: now)
        selection.offer(airing("outside-window", start: 86400, end: 86500), now: now)
        #expect(selection.programmes.count == 4)
        #expect(selection.programmes.map(\.id).sorted() == ["episode-2", "episode-3", "episode-4", "favorite"])
        #expect(LiveTVHubPolicy.discovery(selection.programmes, now: now.addingTimeInterval(120), liveOnly: true).map(\.id) == ["episode-2"])
    }

    @Test func `editorial collections require coverage preserve station order and prefer favorites`() {
        let channels = [channel("one", name: "UK | BBC One HD"), channel("two", name: "BBC Two FHD"),
                        channel("itv", name: "ITV 1"), channel("favorite", name: "Custom BBC", epgID: "BBCOne.uk", favorite: true),
                        channel("timeshift", name: "BBC One +1"), channel("region", name: "BBC One Scotland")]
        let collections = LiveTVChannelCollections.resolve(channels)
        #expect(collections.count == 1)
        #expect(collections.first?.channels.map(\.id) == ["favorite", "two", "itv"])
        #expect(LiveTVChannelCollections.resolve(Array(channels.prefix(2))).isEmpty)
        #expect(LiveTVChannelCollections.channelKey("BBC One +1") != LiveTVTitleIndex.key("BBC One"))
        #expect(LiveTVChannelCollections.channelKey("BBC One Scotland") != LiveTVTitleIndex.key("BBC One"))
    }
}

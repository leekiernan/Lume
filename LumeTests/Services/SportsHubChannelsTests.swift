import Foundation
@testable import Lume
import Testing

struct SportsHubChannelsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func channel(_ id: String) -> ResolvedChannel {
        ResolvedChannel(
            stream: ResolvedStreamSummary(id: id, name: id, streamIcon: nil, epgChannelId: nil),
            playlistID: UUID(), matchedTitle: nil, matchedStart: nil, score: 1, source: .epgTitleSubtitle, isConfident: false
        )
    }

    private func answer(
        current: [String: [ResolvedChannel]], cached: [String: [ResolvedChannel]], token: String = "parent"
    ) throws -> SportsHubChannels {
        var resolution = SportsFixtureResolutionMachine()
        if !current.isEmpty {
            let fixtures = current.keys.map {
                SportsFixture(id: $0, leagueId: "league", leagueName: "", leagueAbbreviation: "", startDate: now,
                              status: SportsFixtureStatus(state: .scheduled))
            }
            let begun = resolution.begin(fixtures, visibilityToken: "parent")
            let request = try #require(begun)
            resolution.publish(request, current)
        }
        var highlights = SportsHighlightsLoadMachine()
        let request = highlights.begin(visibilityToken: "parent")
        highlights.finish(request, result: .init(highlights: [], resolved: cached))
        return SportsHubChannels(resolution: resolution, highlights: highlights, visibilityToken: token)
    }

    @Test func `a known empty answer cannot be resurrected by highlights`() throws {
        let channels = try answer(current: ["game": []], cached: ["game": [channel("cached")]])
        #expect(channels.resolved["game"] == [])
        #expect(channels.availableIDs.isEmpty)
        #expect(SportsChannelAvailability(channels.resolved["game"], startDate: now, now: now) == .none)
    }

    @Test func `current channels replace the cached answer`() throws {
        let current = channel("current")
        let channels = try answer(current: ["game": [current]], cached: ["game": [channel("cached")]])
        #expect(channels.resolved["game"] == [current])
        #expect(channels.availableIDs == ["game"])
    }

    @Test func `a highlight supplies both hero eligibility and sheet channels before hub resolution`() throws {
        let cached = channel("cached")
        let channels = try answer(current: [:], cached: ["game": [cached]])
        #expect(channels.availableIDs == ["game"])
        #expect(channels.resolved["game"] == [cached])
        #expect(SportsChannelAvailability(channels.resolved["game"], startDate: now, now: now).isAvailable)
        #expect(channels.resolved["unresolved"] == nil)
    }

    @Test func `neither source may leak channels after visibility changes`() throws {
        let channels = try answer(current: ["current": [channel("current")]], cached: ["cached": [channel("cached")]], token: "child")
        #expect(channels.resolved.isEmpty)
        #expect(channels.availableIDs.isEmpty)
    }

    @Test func `an empty far-future answer retains the guide horizon semantics`() throws {
        let channels = try answer(current: ["game": []], cached: [:])
        #expect(channels.availableIDs.isEmpty)
        #expect(SportsChannelAvailability(channels.resolved["game"], startDate: now.addingTimeInterval(4 * 86400), now: now) == .unknown)
    }
}

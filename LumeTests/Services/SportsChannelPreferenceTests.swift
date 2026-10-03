//
//  SportsChannelPreferenceTests.swift
//  LumeTests
//
//  Which channel Play opens: the resolver's tier first, then the viewer's
//  language, then the quality that suits the screen.
//

import Foundation
@testable import Lume
import Testing

struct SportsChannelPreferenceTests {
    private func channel(_ name: String, source: ResolvedChannelSource = .epgTitleSubtitle) -> ResolvedChannel {
        ResolvedChannel(
            stream: ResolvedStreamSummary(id: name, name: name, streamIcon: nil, epgChannelId: nil),
            playlistID: UUID(), matchedTitle: nil, matchedStart: nil, score: 1, source: source, isConfident: false
        )
    }

    @Test func `language prefixes are read, ambiguous ones are not`() {
        #expect(SportsChannelPreference.language(ofChannelNamed: "UK: Sky Sports Main Event") == "en")
        #expect(SportsChannelPreference.language(ofChannelNamed: "DE | Sky Sport Bundesliga 1") == "de")
        #expect(SportsChannelPreference.language(ofChannelNamed: "[EN] beIN Sports 1") == "en")
        #expect(SportsChannelPreference.language(ofChannelNamed: "FR- Canal+ Sport") == "fr")
        #expect(SportsChannelPreference.language(ofChannelNamed: "Sky Sports Main Event") == nil)
        #expect(SportsChannelPreference.language(ofChannelNamed: "AR: beIN Sports") == nil)
    }

    @Test func `the viewer's language beats quality within a tier`() {
        let context = SportsChannelPreference.Context(preferredLanguages: ["en"], displayIs4K: true)
        let ordered = SportsChannelPreference.ordered(
            [channel("DE: Sky Sport UHD"), channel("UK: Sky Sports HD")], context: context
        )
        #expect(ordered.map(\.stream.name) == ["UK: Sky Sports HD", "DE: Sky Sport UHD"])
    }

    @Test func `a 1080p screen prefers FHD, a 4K one UHD`() {
        let channels = [channel("UK: Sports 4K UHD"), channel("UK: Sports FHD")]
        let tv1080 = SportsChannelPreference.ordered(channels, context: .init(preferredLanguages: ["en"], displayIs4K: false))
        let tv4K = SportsChannelPreference.ordered(channels, context: .init(preferredLanguages: ["en"], displayIs4K: true))
        #expect(tv1080.first?.stream.name == "UK: Sports FHD")
        #expect(tv4K.first?.stream.name == "UK: Sports 4K UHD")
    }

    @Test func `a stronger tier always wins`() {
        let context = SportsChannelPreference.Context(preferredLanguages: ["en"], displayIs4K: false)
        let ordered = SportsChannelPreference.ordered(
            [channel("UK: Sports FHD", source: .channelName), channel("DE: Sport", source: .userPick)], context: context
        )
        #expect(ordered.first?.stream.name == "DE: Sport")
    }
}

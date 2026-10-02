//
//  SportsChannelAvailabilityTests.swift
//  LumeTests
//
//  The card's channel line: silent until the resolver answers, honest about
//  "not on your channels" only while a guide could cover the game.
//

import Foundation
@testable import Lume
import Testing

struct SportsChannelAvailabilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func channel(_ id: String, _ name: String) -> ResolvedChannel {
        ResolvedChannel(
            stream: ResolvedStreamSummary(id: id, name: name, streamIcon: nil, epgChannelId: nil),
            playlistID: UUID(), matchedTitle: nil, matchedStart: nil, score: 1, source: .epgTitleSubtitle, isConfident: false
        )
    }

    @Test func `nothing to say before the resolver answers`() {
        let availability = SportsChannelAvailability(nil, startDate: now, now: now)
        #expect(availability == .unknown)
        #expect(availability.label == nil)
    }

    @Test func `an empty answer near kickoff means not carried`() {
        let availability = SportsChannelAvailability([], startDate: now.addingTimeInterval(3600), now: now)
        #expect(availability == .none)
        #expect(availability.label == String(localized: "Not in your channels"))
    }

    @Test func `an empty answer days ahead means no guide yet`() {
        let availability = SportsChannelAvailability([], startDate: now.addingTimeInterval(4 * 86400), now: now)
        #expect(availability == .unknown)
    }

    @Test func `the same channel from two playlists counts once`() {
        let resolved = [channel("a", "Sky Sports Main Event"), channel("b", "sky sports main event "), channel("c", "TNT Sports 1")]
        let availability = SportsChannelAvailability(resolved, startDate: now, now: now)
        guard case let .available(count, best) = availability else {
            Issue.record("expected available")
            return
        }
        #expect(count == 2)
        #expect(best.id == "a")
        #expect(availability.label == String(localized: "On \(2) of your channels"))
    }
}

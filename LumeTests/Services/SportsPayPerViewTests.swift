//
//  SportsPayPerViewTests.swift
//  LumeTests
//
//  Pay-per-view and event channels: recognised by their name or category, an
//  event read from a renamed channel, placeholder guide rows skipped; and the
//  "Big this week" wording that goes with them — a race weekend's sessions
//  named for what they are, practice left out, "Big event" where there's no game.
//

import Foundation
@testable import Lume
import Testing

struct SportsPayPerViewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [
        "PPV 05", "US: PPV05", "UK | PPV-3", "Sky Sports Box Office", "DAZN PPV", "LIVE EVENT 3", "Events 12",
        "US (PPV 05) | UFC 310 Pantoja vs Asakura", "Pay-Per-View 2"
    ])
    func `recognises pay-per-view and event channels`(name: String) {
        #expect(SportsPayPerView.isPayPerView(name))
    }

    @Test(arguments: ["Sky Sports Main Event", "BBC One", "Eurosport 1", "TNT Sports 2", "Pop Up Channel"])
    func `leaves ordinary channels alone`(name: String) {
        #expect(!SportsPayPerView.isPayPerView(name))
    }

    @Test func `a pay-per-view category counts for its channels`() {
        #expect(SportsPayPerView.isPayPerView("US 01", categoryName: "USA | PPV EVENTS"))
    }

    @Test func `reads the event from a renamed channel`() {
        #expect(SportsPayPerView.title(fromChannelName: "US (PPV 05) | UFC 310 Pantoja vs Asakura") == "UFC 310 Pantoja vs Asakura")
        #expect(SportsPayPerView.title(fromChannelName: "PPV 2: Canelo vs Crawford") == "Canelo vs Crawford")
    }

    @Test func `a channel name with no event in it gives none`() {
        #expect(SportsPayPerView.title(fromChannelName: "US: PPV 05") == nil)
        #expect(SportsPayPerView.title(fromChannelName: "Sky Sports Box Office HD") == nil)
        #expect(SportsPayPerView.title(fromChannelName: "LIVE EVENT 3") == nil)
    }

    @Test func `skips placeholder guide rows`() {
        #expect(SportsPayPerView.isPlaceholder("No Event", channelName: "PPV 1"))
        #expect(SportsPayPerView.isPlaceholder("Off Air", channelName: "PPV 1"))
        #expect(SportsPayPerView.isPlaceholder("PPV 1", channelName: "PPV 1"))
        #expect(SportsPayPerView.isPlaceholder("Sky Sports Box Office", channelName: "Box Office 1"))
        #expect(!SportsPayPerView.isPlaceholder("UFC 310: Pantoja vs Asakura", channelName: "PPV 1"))
    }

    @Test func `orders live first, then by start, name-only last`() {
        func event(_ id: String, start: TimeInterval?) -> SportsPayPerView.Event {
            SportsPayPerView.Event(
                id: id, title: id, start: start.map { now.addingTimeInterval($0) },
                end: start.map { now.addingTimeInterval($0 + 3 * 3600) }, channelName: "PPV", streamId: id, logoURL: nil
            )
        }
        let ordered = SportsPayPerView.order(
            [event("named", start: nil), event("later", start: 86400), event("live", start: -3600), event("soon", start: 3600)],
            now: now
        )
        #expect(ordered.map(\.id) == ["live", "soon", "later", "named"])
    }

    @Test func `drops an event a highlight already shows from the same channel`() {
        let fight = SportsFixture(
            id: "ufc", leagueId: "espn:mma/ufc", leagueName: "UFC", leagueAbbreviation: "UFC",
            startDate: now.addingTimeInterval(3600), status: SportsFixtureStatus(state: .scheduled), name: "UFC 310"
        )
        let highlight = SportsHighlight(fixture: fight, reason: .payPerView, score: 80)
        let same = SportsPayPerView.Event(
            id: "a", title: "UFC 310", start: now.addingTimeInterval(3000), end: nil,
            channelName: "PPV 1", streamId: "1", logoURL: nil
        )
        let other = SportsPayPerView.Event(
            id: "b", title: "Boxing", start: now.addingTimeInterval(3000), end: nil,
            channelName: "PPV 2", streamId: "2", logoURL: nil
        )
        let kept = SportsHighlightsPipeline.unclaimed([same, other], highlights: [highlight], mainChannels: ["ufc": "PPV 1"])
        #expect(kept.map(\.id) == ["b"])
    }

    // MARK: - Highlight wording

    private func session(_ kind: SportsSessionKind) -> SportsFixture {
        SportsFixture(
            id: "f1#\(kind.rawValue)", leagueId: "espn:racing/f1", leagueName: "F1", leagueAbbreviation: "F1",
            startDate: now.addingTimeInterval(86400), status: SportsFixtureStatus(state: .scheduled),
            name: "Grand Prix", sessionKind: kind
        )
    }

    private func rank(_ fixtures: [SportsFixture], mainChannels: [String: String] = [:]) -> [SportsHighlight] {
        SportsHighlights.rank(
            fixtures, standings: [:], followedTeamIds: [], availableIds: [], mainChannels: mainChannels, now: now
        )
    }

    @Test func `qualifying is named qualifying, not a big game`() {
        let picked = rank([session(.qualifying)])
        #expect(picked.first?.reason == .session(.qualifying))
        #expect(picked.first?.chip == String(localized: "Qualifying"))
    }

    @Test func `practice sessions never make the list`() {
        #expect(rank([session(.fp1), session(.fp2), session(.fp3)]).isEmpty)
    }

    @Test func `the race is still race day`() {
        #expect(rank([session(.race)]).first?.reason == .raceDay)
    }

    @Test func `an event without teams reads as a big event`() {
        let event = SportsFixture(
            id: "x", leagueId: "espn:soccer/uefa.champions", leagueName: "", leagueAbbreviation: "",
            startDate: now.addingTimeInterval(86400), status: SportsFixtureStatus(state: .scheduled), name: "Draw"
        )
        let highlight = SportsHighlight(fixture: event, reason: .headline, score: 30)
        #expect(highlight.chip == String(localized: "Big event"))
    }

    @Test func `a game on a pay-per-view channel says so`() {
        let fight = SportsFixture(
            id: "fight", leagueId: "espn:mma/ufc", leagueName: "UFC", leagueAbbreviation: "UFC",
            startDate: now.addingTimeInterval(86400), status: SportsFixtureStatus(state: .scheduled),
            name: "UFC Fight Night: A vs. B"
        )
        let picked = rank([fight], mainChannels: ["fight": "US: PPV 05"])
        #expect(picked.first?.reason == .payPerView)
    }
}

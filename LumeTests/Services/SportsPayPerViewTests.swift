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

    private func parse(_ name: String) -> SportsEventChannelName.Parsed? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return SportsEventChannelName.parse(name, now: now, calendar: calendar)
    }

    @Test func `reads the event and its time from a provider's event channel`() throws {
        // 1_800_000_000 is Friday 15 Jan 2027, 08:00 UTC.
        let parsed = try #require(parse("US|NFHS Tue 12:00 - Somersworth vs. Laconia"))
        #expect(parsed.title == "Somersworth vs. Laconia")
        #expect(parsed.start == now.addingTimeInterval((4 * 24 + 4) * 3600))
        #expect(!parsed.isLive)
    }

    @Test func `a time earlier today is the game under way, not next week's`() throws {
        let parsed = try #require(parse("UK|DAZN Fri 06:30 - Joshua vs Dubois"))
        #expect(parsed.start == now.addingTimeInterval(-1.5 * 3600))
    }

    @Test func `LIVE in the name means it's on now`() {
        #expect(parse("US|NFHS LIVE - Fife vs. Orting") == .init(title: "Fife vs. Orting", start: nil, isLive: true))
    }

    @Test func `reads the event from a renamed channel without a time`() {
        #expect(parse("US (PPV 05) | UFC 310 Pantoja vs Asakura")?.title == "UFC 310 Pantoja vs Asakura")
        #expect(parse("PPV 2: Canelo vs Crawford")?.title == "Canelo vs Crawford")
    }

    @Test(arguments: ["US|SWAC No event", "US|SWAC Tue 17:50 - No event", "US: PPV 05", "Sky Sports Box Office HD", "LIVE EVENT 3"])
    func `a placeholder or bare channel name gives no event`(name: String) {
        #expect(parse(name) == nil)
    }

    @Test func `a category named for one event`() {
        #expect(SportsEventChannelName.event(inCategory: "UFC Fight Night | Rosas Jr vs Barcelos (Sat)")
            == "UFC Fight Night: Rosas Jr vs Barcelos")
        #expect(SportsEventChannelName.event(inCategory: "LIVE | Rugby (Sat)") == nil)
        #expect(SportsEventChannelName.event(inCategory: "PPV | PPV Events 1") == nil)
    }

    @Test(arguments: ["PPV | PPV Events 1", "PPV | PPV Boxing (Sat)", "LIVE | Requested Live Events"])
    func `the provider's pay-per-view categories count`(category: String) {
        #expect(SportsPayPerView.isPayPerView("Channel 1", categoryName: category))
    }

    @Test(arguments: ["UK | Sky Sports", "UK | TNT Events (Live Only)", "LIVE | EPL", "LIVE | Wrestling (Live Only)"])
    func `ordinary sports categories don't`(category: String) {
        #expect(!SportsPayPerView.isPayPerView("Channel 1", categoryName: category))
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

// MARK: - Fight-card times

struct SportsMainCardTests {
    /// UFC 332 as ESPN lists it: the event dated at the early prelims, each
    /// bout with its own start, the main card last.
    @Test func `a fight card headlines at its main card, not the early prelims`() throws {
        let json = """
        {"id": "600061182", "date": "2026-10-03T20:00Z", "name": "UFC 332: Silva vs. Wang",
         "competitions": [{"date": "2026-10-03T20:00Z"}, {"date": "2026-10-03T22:00Z"}, {"date": "2026-10-04T00:00Z"}]}
        """
        let event = try JSONDecoder().decode(ESPNEvent.self, from: Data(json.utf8))
        let start = Date(timeIntervalSince1970: 1_791_057_600) // 2026-10-03T20:00Z
        let mainCard = try #require(ESPNClient.mainCardDate(event, startDate: start))
        #expect(mainCard == start.addingTimeInterval(4 * 3600))

        let fixture = SportsFixture(
            id: "ufc", leagueId: "espn:mma/ufc", leagueName: "UFC", leagueAbbreviation: "UFC",
            startDate: start, status: SportsFixtureStatus(state: .scheduled), mainCardDate: mainCard
        )
        #expect(fixture.headlineDate == mainCard)
        #expect(fixture.expectedEnd >= mainCard.addingTimeInterval(3 * 3600))
    }

    @Test func `a single-start event has no separate main card`() throws {
        let json = #"{"id": "1", "date": "2026-10-03T20:00Z", "competitions": [{"date": "2026-10-03T20:00Z"}]}"#
        let event = try JSONDecoder().decode(ESPNEvent.self, from: Data(json.utf8))
        #expect(ESPNClient.mainCardDate(event, startDate: Date(timeIntervalSince1970: 1_791_057_600)) == nil)
    }
}

struct SportsEventChannelDateTests {
    /// Thu 1 Oct 2026, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_856_000)

    @Test func `a dated name in Eastern time is read in Eastern time, and leaves the title whole`() throws {
        let parsed = try #require(SportsEventChannelName.parse(
            "US|ESPN+ PPV 125 | #17 Colorado vs. UCF Fri 2 Oct 7:00 PM EDT", now: now
        ))
        #expect(parsed.title == "#17 Colorado vs. UCF")
        // 7 pm EDT is 23:00 UTC.
        #expect(parsed.start == Date(timeIntervalSince1970: 1_790_982_000))
    }

    @Test func `month-first and twenty-four-hour forms`() throws {
        let first = try #require(SportsEventChannelName.datedStart(in: "Oct 3, 8:30PM ET", now: now))
        #expect(first.date == Date(timeIntervalSince1970: 1_791_073_800))
        let second = try #require(SportsEventChannelName.datedStart(in: "Sat 3rd Oct 19:30 BST", now: now))
        #expect(second.date == Date(timeIntervalSince1970: 1_791_052_200))
    }

    @Test func `a bare number isn't a time, and a word after the time stays in the title`() {
        #expect(SportsEventChannelName.datedStart(in: "PPV 2 Oct 125", now: now) == nil)
        let dated = SportsEventChannelName.datedStart(in: "Sat 3 Oct 8PM UFC 310", now: now)
        #expect(dated.map { "Sat 3 Oct 8PM UFC 310".replacingCharacters(in: $0.range, with: "") } == " UFC 310")
    }
}

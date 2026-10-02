//
//  SportsDayWindowTests.swift
//  LumeTests
//
//  Today claims what is on today, not only what started today: a US event in
//  UK time that starts before midnight and runs past it must not drop into
//  Yesterday while it is still on.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsDayWindowTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        return calendar
    }

    /// Sunday 4 October 2026, 02:00 in London.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 2)) ?? Date()
    }

    private func at(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour)) ?? Date()
    }

    private func fixture(sport: String, start: Date, state: SportsFixtureState) -> SportsFixture {
        SportsFixture(
            id: "\(sport)-\(start.timeIntervalSince1970)",
            leagueId: "espn:\(sport)/test",
            leagueName: "Test",
            leagueAbbreviation: "TST",
            startDate: start,
            status: SportsFixtureStatus(state: state),
            name: "Event"
        )
    }

    @Test func `a fight card that started last night is still today after midnight`() {
        let card = fixture(sport: "mma", start: at(day: 3, hour: 23), state: .scheduled)

        #expect(SportsHubView.fixture(card, isIn: .today, now: now, calendar: calendar))
        #expect(SportsHubView.fixture(card, isIn: .yesterday, now: now, calendar: calendar))
    }

    @Test func `a finished card that ran past midnight stays in today`() {
        let card = fixture(sport: "mma", start: at(day: 3, hour: 23), state: .final)

        #expect(SportsHubView.fixture(card, isIn: .today, now: now, calendar: calendar))
    }

    @Test func `yesterday afternoon's match is not today`() {
        let match = fixture(sport: "soccer", start: at(day: 3, hour: 15), state: .final)

        #expect(!SportsHubView.fixture(match, isIn: .today, now: now, calendar: calendar))
        #expect(SportsHubView.fixture(match, isIn: .yesterday, now: now, calendar: calendar))
    }

    @Test func `anything the provider calls live is today`() {
        let longGame = fixture(sport: "cricket", start: at(day: 2, hour: 10), state: .inProgress)

        #expect(SportsHubView.fixture(longGame, isIn: .today, now: now, calendar: calendar))
    }

    @Test func `upcoming still goes by start`() {
        let later = fixture(sport: "soccer", start: at(day: 4, hour: 16), state: .scheduled)
        let started = fixture(sport: "mma", start: at(day: 3, hour: 23), state: .scheduled)

        #expect(SportsHubView.fixture(later, isIn: .upcoming, now: now, calendar: calendar))
        #expect(!SportsHubView.fixture(started, isIn: .upcoming, now: now, calendar: calendar))
    }

    @Test func `an expanded race session uses the session's own length`() {
        let session = SportsFixture(
            id: "gp#Race", leagueId: "espn:racing/f1", leagueName: "F1", leagueAbbreviation: "F1",
            startDate: at(day: 3, hour: 21), status: SportsFixtureStatus(state: .final), sessionKind: .race
        )

        // 21:00 + 2.5 h ends before midnight.
        #expect(!SportsHubView.fixture(session, isIn: .today, now: now, calendar: calendar))
    }
}

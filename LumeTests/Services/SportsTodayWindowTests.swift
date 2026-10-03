//
//  SportsTodayWindowTests.swift
//  LumeTests
//
//  The Home rail's Today claims what is on today, not only what started
//  today: a US event in UK time that starts before midnight and runs past it
//  must still count while it is on (`SportsRailPlanner`'s window rule).
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsTodayWindowTests {
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

    /// Calls the production rail rule rather than duplicating it in this test.
    private func isToday(_ fixture: SportsFixture) -> Bool {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return SportsRailPlanner.isInWindow(fixture, start: start, end: end)
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

        #expect(isToday(card))
    }

    @Test func `a finished card that ran past midnight stays in today`() {
        let card = fixture(sport: "mma", start: at(day: 3, hour: 23), state: .final)

        #expect(isToday(card))
    }

    @Test func `yesterday afternoon's match is not today`() {
        let match = fixture(sport: "soccer", start: at(day: 3, hour: 15), state: .final)

        #expect(!isToday(match))
    }

    @Test func `anything the provider calls live is today`() {
        let longGame = fixture(sport: "cricket", start: at(day: 2, hour: 10), state: .inProgress)

        #expect(isToday(longGame))
    }

    @Test func `an expanded race session uses the session's own length`() {
        let session = SportsFixture(
            id: "gp#Race", leagueId: "espn:racing/f1", leagueName: "F1", leagueAbbreviation: "F1",
            startDate: at(day: 3, hour: 21), status: SportsFixtureStatus(state: .final), sessionKind: .race
        )

        // 21:00 + 2.5 h ends before midnight.
        #expect(!isToday(session))
    }
}

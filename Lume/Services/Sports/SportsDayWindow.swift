//
//  SportsDayWindow.swift
//  Lume
//
//  A day window over fixtures — Yesterday, Today, Upcoming — as the league
//  screen offers them. Today claims what is live or on at any point today, so
//  an event that started last night and runs past midnight stays in Today;
//  the other windows go by the headline start (a fight card's main card, a
//  race weekend's race).
//

import Foundation

nonisolated enum SportsDayWindow: String, CaseIterable, Identifiable {
    case yesterday
    case today
    case upcoming

    var id: String {
        rawValue
    }

    /// The half-open interval the window covers, relative to `now`.
    func range(now: Date, calendar: Calendar = .current) -> Range<Date> {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return start ..< startOfToday
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            return startOfToday ..< end
        case .upcoming:
            let end = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? startOfToday
            return now ..< end
        }
    }

    /// Whether `fixture` belongs in the window.
    func contains(_ fixture: SportsFixture, now: Date, calendar: Calendar = .current) -> Bool {
        let range = range(now: now, calendar: calendar)
        switch self {
        case .today:
            return fixture.isInProgress || fixture.isOn(during: range)
        case .yesterday, .upcoming:
            return range.contains(fixture.headlineDate)
        }
    }
}

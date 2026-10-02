//
//  SportsFixture+Window.swift
//  Lume
//
//  How long an event is expected to run, so a day can claim everything that is
//  on during it — not only what started during it. A UFC card that starts at
//  23:00 in the UK and runs into the small hours belongs to tonight's Today
//  after midnight too; bucketing by start alone dropped it into Yesterday while
//  it was still live.
//

import Foundation

nonisolated extension SportsFixture {
    /// A generous typical running time for the sport, used only to decide which
    /// days an event is on during — never shown. Generous, because an event
    /// lingering in Today a little long costs nothing, while one vanishing
    /// mid-event is the bug this exists for.
    var expectedDuration: TimeInterval {
        if let sessionKind {
            return sessionKind == .race ? 2.5 * 3600 : 1.25 * 3600
        }
        switch sport {
        case "soccer", "rugby", "rugby-league": return 2.25 * 3600
        case "basketball", "lacrosse": return 2.75 * 3600
        case "hockey": return 3 * 3600
        case "football", "baseball", "australian-football": return 3.75 * 3600
        case "tennis": return 4 * 3600
        case "cricket": return 8 * 3600
        case "mma", "boxing": return 6 * 3600
        case "racing":
            // An unexpanded weekend runs until its race is over.
            if let race = raceSession?.date { return race.timeIntervalSince(startDate) + 2.5 * 3600 }
            return 2.5 * 3600
        default: return 3 * 3600
        }
    }

    /// When the event is expected to be over.
    var expectedEnd: Date {
        startDate.addingTimeInterval(max(expectedDuration, 0))
    }

    /// Whether the event is on at any point inside `range`.
    func isOn(during range: Range<Date>) -> Bool {
        startDate < range.upperBound && expectedEnd > range.lowerBound
    }
}

nonisolated extension SportsFixture {
    /// When a card says a game is: the time alone for today, the weekday
    /// and time otherwise, so a Saturday kickoff in Thursday's list is never
    /// read as today's.
    var cardWhenText: String {
        if startTimeIsTentative == true {
            return headlineDate.formatted(.dateTime.weekday(.abbreviated))
        }
        return headlineIsToday
            ? headlineDate.formatted(.dateTime.hour().minute())
            : headlineDate.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

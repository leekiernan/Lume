//
//  SportsSyncService+Schedule.swift
//  Lume
//
//  The pure scheduling rules behind the Sports refresh: which fixtures are
//  overdue, which days the live poll and a catch-up fetch, which months a
//  refresh covers, and which league a team belongs to. No state — kept apart
//  from the service so they read (and are unit-tested) on their own.
//

import Foundation

extension SportsSyncService {
    /// A game is worth polling while the snapshot calls it live — or still
    /// "scheduled" for a kickoff that has passed, which is what a stale snapshot
    /// looks like once the day's games have started. Both are bounded by
    /// `overdueLookback`: a game "live" since last night is polled (and its own
    /// day fetched) until the provider closes it out; one from last week is
    /// left to the scheduled refresh.
    nonisolated static func isOverdue(_ fixture: SportsFixture, now: Date) -> Bool {
        switch fixture.status.state {
        case .inProgress, .scheduled:
            fixture.startDate <= now && fixture.startDate > now.addingTimeInterval(-overdueLookback)
        case .final, .postponed:
            false
        }
    }

    /// Whether a catch-up is worth a request: no snapshot yet, or the newest one
    /// is older than `catchUpStaleness`.
    nonisolated static func needsCatchUp(newestFetch: Date?, now: Date) -> Bool {
        guard let newestFetch else { return true }
        return now.timeIntervalSince(newestFetch) > catchUpStaleness
    }

    /// The calendar days the live poll fetches: the day of every overdue fixture.
    /// Empty when nothing is live or overdue, so an idle hub costs no requests.
    /// Sorted and unique so a day is never fetched twice per pass.
    nonisolated static func pollDays(fixtures: [SportsFixture], now: Date, calendar: Calendar = .current) -> [Date] {
        let overdue = fixtures.lazy.filter { isOverdue($0, now: now) }.map { calendar.startOfDay(for: $0.startDate) }
        return Array(Set(overdue)).sorted()
    }

    /// The calendar days a catch-up fetches: today, yesterday (late games ending
    /// after midnight, and time zones where the provider's day differs from the
    /// viewer's) and the day of every overdue fixture.
    nonisolated static func catchUpDays(fixtures: [SportsFixture], now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        var days: Set<Date> = [today]
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            days.insert(yesterday)
        }
        days.formUnion(pollDays(fixtures: fixtures, now: now, calendar: calendar))
        return days.sorted()
    }

    /// The league id embedded in a team id ("espn:soccer/ger.1:132" → "espn:soccer/ger.1").
    nonisolated static func leagueId(fromTeamID teamID: String) -> String? {
        guard let range = teamID.range(of: ":", options: .backwards) else { return nil }
        return String(teamID[..<range.lowerBound])
    }

    /// The calendar months a refresh should fetch: the current month, plus the
    /// next month when the date is within 7 days of the current month's end (so a
    /// fixture list never runs dry at a month boundary). Pure, so it is unit-tested.
    nonisolated static func monthsToFetch(for date: Date, calendar: Calendar = .current) -> [DateComponents] {
        let current = calendar.dateComponents([.year, .month], from: date)
        var months = [current]
        let day = calendar.component(.day, from: date)
        if let range = calendar.range(of: .day, in: .month, for: date),
           range.count - day <= 7,
           let nextMonth = calendar.date(byAdding: .month, value: 1, to: date)
        {
            months.append(calendar.dateComponents([.year, .month], from: nextMonth))
        }
        return months
    }
}

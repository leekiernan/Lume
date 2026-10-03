//
//  SportsSyncService+Schedule.swift
//  Lume
//
//  The pure scheduling rules behind the Sports refresh: when a league's
//  snapshot is still fresh, which fixtures are overdue, which days the live
//  poll fetches, which months a refresh covers, and which league a team
//  belongs to. No state — kept apart
//  from the service so they read (and are unit-tested) on their own.
//

import Foundation

extension SportsSyncService {
    /// Results are useful briefly (Yesterday and a late-running fixture), while
    /// schedules need enough runway to bridge the next month boundary. Keeping
    /// every completed fixture ever seen made the derived JSON cache grow for a
    /// whole season even though no Sports surface could display those rows.
    nonisolated static let finishedFixtureRetention: TimeInterval = 14 * 24 * 60 * 60
    nonisolated static let upcomingFixtureRetention: TimeInterval = 45 * 24 * 60 * 60

    nonisolated static func retainedFixtures(_ fixtures: [SportsFixture], now: Date = Date()) -> [SportsFixture] {
        fixtures.filter { fixture in
            switch fixture.status.state {
            case .inProgress:
                true
            case .final:
                fixture.expectedEnd >= now.addingTimeInterval(-finishedFixtureRetention)
            case .scheduled, .postponed:
                fixture.expectedEnd >= now.addingTimeInterval(-finishedFixtureRetention)
                    && fixture.startDate <= now.addingTimeInterval(upcomingFixtureRetention)
            }
        }
    }

    /// Whether a league's snapshot is recent enough to skip a full refresh.
    nonisolated static func isFresh(_ snapshot: SportsLeagueSnapshot?, now: Date) -> Bool {
        guard let snapshot else { return false }
        return now.timeIntervalSince(snapshot.fetchedAt) < freshness
    }

    /// A game is worth polling while the snapshot calls it live — or still
    /// "scheduled" for a kickoff that has passed, which is what a stale snapshot
    /// looks like once the day's games have started. Both are bounded by
    /// `overdueLookback`: a game "live" since last night is polled (and its own
    /// day fetched) until the provider closes it out; one from last week is
    /// left to the month refresh.
    nonisolated static func isOverdue(_ fixture: SportsFixture, now: Date) -> Bool {
        switch fixture.status.state {
        case .inProgress, .scheduled:
            fixture.startDate <= now && fixture.startDate > now.addingTimeInterval(-overdueLookback)
        case .final, .postponed:
            false
        }
    }

    /// The calendar days the live poll fetches: the day of every overdue fixture.
    /// Empty when nothing is live or overdue, so an idle hub costs no requests.
    /// Sorted and unique so a day is never fetched twice per pass.
    nonisolated static func pollDays(fixtures: [SportsFixture], now: Date, calendar: Calendar = .current) -> [Date] {
        let overdue = fixtures.lazy.filter { isOverdue($0, now: now) }.map { calendar.startOfDay(for: $0.startDate) }
        return Array(Set(overdue)).sorted()
    }

    /// The league id embedded in a team id ("espn:soccer/ger.1:132" → "espn:soccer/ger.1").
    nonisolated static func leagueId(fromTeamID teamID: String) -> String? {
        guard let range = teamID.range(of: ":", options: .backwards) else { return nil }
        return String(teamID[..<range.lowerBound])
    }

    /// The calendar months a refresh should fetch: the current month, plus the
    /// next month when the date is within 7 days of the current month's end (so a
    /// fixture list never runs dry at a month boundary), plus the previous month
    /// on the 1st (yesterday's late games, and time zones where the provider's
    /// day differs from the viewer's). Pure, so it is unit-tested.
    nonisolated static func monthsToFetch(for date: Date, calendar: Calendar = .current) -> [DateComponents] {
        let current = calendar.dateComponents([.year, .month], from: date)
        var months = [current]
        let day = calendar.component(.day, from: date)
        if day == 1, let previousMonth = calendar.date(byAdding: .month, value: -1, to: date) {
            months.insert(calendar.dateComponents([.year, .month], from: previousMonth), at: 0)
        }
        if let range = calendar.range(of: .day, in: .month, for: date),
           range.count - day <= 7,
           let nextMonth = calendar.date(byAdding: .month, value: 1, to: date)
        {
            months.append(calendar.dateComponents([.year, .month], from: nextMonth))
        }
        return months
    }
}

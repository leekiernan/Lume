//
//  SportsReminders.swift
//  Lume
//
//  "Remind me" on a game that hasn't started. tvOS shows no notification
//  banners, so a reminder speaks through the player: while anything plays,
//  the alert coordinator raises a kick-off toast for it, whether or not the
//  viewer follows the teams or has alerts switched on — they asked for this
//  one. Kept on this device, and dropped once it has fired or the game is
//  long past.
//

import Foundation

@MainActor
@Observable
final class SportsReminders {
    static let shared = SportsReminders()

    nonisolated struct Reminder: Codable, Equatable {
        let fixtureId: String
        let leagueId: String
        let start: Date
    }

    static let defaultsKey = "sports.reminders.v1"
    /// A reminder for a game that started this long ago is spent.
    static let staleAfter: TimeInterval = 3 * 3600

    private let defaults: UserDefaults
    private(set) var reminders: [String: Reminder]

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: Reminder].self, from: $0) } ?? [:]
        reminders = stored.filter { now.timeIntervalSince($0.value.start) < Self.staleAfter }
    }

    func isReminded(_ fixtureId: String) -> Bool {
        reminders[fixtureId] != nil
    }

    func toggle(_ fixture: SportsFixture) {
        if reminders[fixture.id] != nil {
            reminders[fixture.id] = nil
        } else {
            reminders[fixture.id] = Reminder(fixtureId: fixture.id, leagueId: fixture.leagueId, start: fixture.startDate)
        }
        persist()
    }

    /// Reminders whose game is about to start or has just started.
    func due(now: Date) -> [Reminder] {
        reminders.values.filter { $0.start <= now.addingTimeInterval(60) && now.timeIntervalSince($0.start) < Self.staleAfter }
    }

    func fired(_ fixtureId: String) {
        reminders[fixtureId] = nil
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(reminders), forKey: Self.defaultsKey)
    }
}

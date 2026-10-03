//
//  SportsRemindersTests.swift
//  LumeTests
//
//  "Remind me": toggled per game, due as it starts, spent once fired or long
//  past, and kept across launches on this device.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsRemindersTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        let name = "SportsRemindersTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private func game(_ id: String, offset: TimeInterval) -> SportsFixture {
        SportsFixture(
            id: id, leagueId: "espn:mma/ufc", leagueName: "UFC", leagueAbbreviation: "UFC",
            startDate: now.addingTimeInterval(offset), status: SportsFixtureStatus(state: .scheduled)
        )
    }

    @Test func `a reminder is due as its game starts, not before`() {
        let reminders = SportsReminders(defaults: defaults(), now: now)
        reminders.toggle(game("soon", offset: 30))
        reminders.toggle(game("later", offset: 3600))

        #expect(reminders.due(now: now).map(\.fixtureId) == ["soon"])
    }

    @Test func `toggling twice clears it, firing spends it`() {
        let reminders = SportsReminders(defaults: defaults(), now: now)
        reminders.toggle(game("a", offset: 0))
        reminders.toggle(game("a", offset: 0))
        #expect(!reminders.isReminded("a"))

        reminders.toggle(game("b", offset: 0))
        reminders.fired("b")
        #expect(!reminders.isReminded("b"))
    }

    @Test func `reminders survive a restart until long past`() {
        let store = defaults()
        SportsReminders(defaults: store, now: now).toggle(game("a", offset: 600))

        #expect(SportsReminders(defaults: store, now: now).isReminded("a"))
        #expect(!SportsReminders(defaults: store, now: now.addingTimeInterval(4 * 3600)).isReminded("a"))
    }
}

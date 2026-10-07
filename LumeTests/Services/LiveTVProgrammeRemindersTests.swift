import Foundation
@testable import Lume
import Testing

@MainActor struct LiveTVProgrammeRemindersTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(id: String = "guide-row", channel: String = "channel", start: TimeInterval = 60) -> LiveTVHubProgramme {
        .init(id: id, channel: .init(id: channel, name: "Channel", logoURL: nil, epgID: nil, isFavorite: false),
              title: "Programme", start: now.addingTimeInterval(start), end: now.addingTimeInterval(start + 3600),
              artworkURL: nil, overview: "", candidateID: nil, rank: 0)
    }

    @Test func `cancelling while notification scheduling is suspended cancels the late result`() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var continuation: CheckedContinuation<Bool, Never>?
        var cancelled: [String] = []
        let dependencies = LiveTVProgrammeReminders.Dependencies(schedule: { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }, cancel: { cancelled += $0 }, currentProfile: { "profile-a" })
        let store = LiveTVProgrammeReminders(defaults: defaults, dependencies: dependencies, now: now)
        let addition = Task { await store.toggle(programme(), profile: "profile-a", now: now) }
        while continuation == nil {
            await Task.yield()
        }
        await store.toggle(programme(), profile: "profile-a", now: now)
        continuation?.resume(returning: true)
        await addition.value
        #expect(store.reminders.isEmpty)
        #expect(cancelled.count == 2)
    }

    @Test func `missed reminders expire silently and pending requests are bounded`() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var scheduled = 0
        let dependencies = LiveTVProgrammeReminders.Dependencies(schedule: { _, _ in scheduled += 1; return true },
                                                                 cancel: { _ in }, currentProfile: { "profile-a" })
        let store = LiveTVProgrammeReminders(defaults: defaults, dependencies: dependencies, now: now)
        for index in 0 ... LiveTVProgrammeReminders.limit {
            await store.toggle(programme(channel: "channel-\(index)"), profile: "profile-a", now: now)
        }
        #expect(scheduled == LiveTVProgrammeReminders.limit)
        #expect(store.reminders.count == LiveTVProgrammeReminders.limit)
        let notifications = InAppNotifications()
        store.deliverDue(profile: "profile-a", now: now.addingTimeInterval(361), canShow: { _ in true }, notifications: notifications)
        #expect(notifications.pending.isEmpty)
        #expect(store.reminders.isEmpty)
    }

    @Test func `setting removing and reloading use airing identity not guide row identity`() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var scheduled: [LiveTVProgrammeReminders.Reminder] = []
        var cancelled: [String] = []
        let dependencies = LiveTVProgrammeReminders.Dependencies(schedule: { reminder, _ in scheduled.append(reminder); return true },
                                                                 cancel: { cancelled += $0 }, currentProfile: { "profile-a" })
        let store = LiveTVProgrammeReminders(defaults: defaults, dependencies: dependencies, now: now)
        await store.toggle(programme(), profile: "profile-a", now: now)
        #expect(scheduled.count == 1)
        let reloaded = LiveTVProgrammeReminders(defaults: defaults, dependencies: dependencies, now: now)
        #expect(reloaded.reminders.count == 1)
        await reloaded.toggle(programme(id: "replacement-row"), profile: "profile-a", now: now)
        #expect(reloaded.reminders.isEmpty)
        #expect(cancelled == scheduled.map(\.id))
    }

    @Test func `due reminders fire once expire and respect profile and channel visibility`() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let dependencies = LiveTVProgrammeReminders.Dependencies(schedule: { _, _ in true }, cancel: { _ in }, currentProfile: { "profile-a" })
        let store = LiveTVProgrammeReminders(defaults: defaults, dependencies: dependencies, now: now)
        await store.toggle(programme(), profile: "profile-a", now: now)
        await store.toggle(programme(channel: "hidden"), profile: "profile-a", now: now)
        await store.toggle(programme(channel: "expired", start: 1), profile: "profile-a", now: now)
        let notifications = InAppNotifications()
        store.deliverDue(profile: "profile-b", now: now.addingTimeInterval(61), canShow: { _ in true }, notifications: notifications)
        #expect(notifications.pending.isEmpty)
        store.deliverDue(profile: "profile-a", now: now.addingTimeInterval(61), canShow: { $0.channelID != "hidden" }, notifications: notifications)
        #expect(notifications.pending.count == 2)
        store.deliverDue(profile: "profile-a", now: now.addingTimeInterval(62), canShow: { _ in true }, notifications: notifications)
        #expect(notifications.pending.count == 2)
        #expect(store.reminders.isEmpty)
    }

    @Test func `old reminders are not replayed and past programmes cannot be added`() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var schedules = 0
        let dependencies = LiveTVProgrammeReminders.Dependencies(schedule: { _, _ in schedules += 1; return true },
                                                                 cancel: { _ in }, currentProfile: { "profile-a" })
        let store = LiveTVProgrammeReminders(defaults: defaults, dependencies: dependencies, now: now)
        await store.toggle(programme(start: -1), profile: "profile-a", now: now)
        await store.toggle(programme(), profile: "profile-b", now: now)
        #expect(schedules == 0)
        await store.toggle(programme(), profile: "profile-a", now: now)
        let reloaded = LiveTVProgrammeReminders(defaults: defaults, dependencies: dependencies, now: now.addingTimeInterval(361))
        #expect(reloaded.reminders.isEmpty)
    }

    @Test func `switch cancels other profile alerts retains choices and reschedules without prompting`() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var active = "profile-a"
        var prompts: [Bool] = []
        var cancelled: [String] = []
        let dependencies = LiveTVProgrammeReminders.Dependencies(schedule: { _, prompt in prompts.append(prompt); return true },
                                                                 cancel: { cancelled += $0 }, currentProfile: { active })
        let store = LiveTVProgrammeReminders(defaults: defaults, dependencies: dependencies, now: now)
        await store.toggle(programme(), profile: active, now: now)
        active = "profile-b"
        await store.activate(profile: active, now: now)
        #expect(cancelled.count == 1)
        #expect(store.reminders.count == 1)
        active = "profile-a"
        await store.activate(profile: active, now: now)
        #expect(prompts == [true, false])
        await store.activate(profile: active, now: now, canShow: { _ in false })
        #expect(store.reminders.isEmpty)
    }
}

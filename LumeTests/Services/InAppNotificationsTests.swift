import Foundation
@testable import Lume
import Testing

@MainActor
struct InAppNotificationsTests {
    @Test func `programme reminders share the queue without masquerading as sync results`() throws {
        let notifications = InAppNotifications()
        report(.succeeded, to: notifications)
        notifications.remind(id: "airing", title: "Programme", channel: "Channel", profileToken: "profile-a")
        #expect(notifications.pending.count == 2)
        let reminder = try #require(notifications.pending.last)
        #expect(reminder.outcome == nil)
        #expect(reminder.subject == .programme("airing", title: "Programme", channel: "Channel"))
        notifications.retainProfile("profile-b")
        #expect(notifications.pending.isEmpty)
    }

    private func report(
        _ outcome: SyncRefreshOutcome,
        to notifications: InAppNotifications,
        subject: InAppNotifications.Subject = .guide,
        started: String = "profile-a",
        current: String = "profile-a"
    ) {
        notifications.report(outcome, subject: subject, startedUnder: started, currentProfileToken: current)
    }

    @Test(arguments: [SyncRefreshOutcome.succeeded, .succeededWithWarnings, .failed])
    func `success and failure each queue a single completion`(_ outcome: SyncRefreshOutcome) throws {
        let notifications = InAppNotifications()
        report(outcome, to: notifications)
        let notice = try #require(notifications.pending.first)
        #expect(notice.outcome == outcome)
        #expect(notice.subject == .guide)
        #expect(notifications.pending.count == 1)
    }

    @Test func `supplementary warnings retain their explanation without failing the provider`() throws {
        let notifications = InAppNotifications()
        notifications.report(.succeededWithWarnings, subject: .guide, startedUnder: "profile-a", currentProfileToken: "profile-a", detail: "EPGShare unavailable")
        let notice = try #require(notifications.pending.first)
        #expect(notice.outcome?.isSuccessful == true)
        #expect(notice.outcome == .succeededWithWarnings)
        #expect(notice.detail == "EPGShare unavailable")
        report(.succeeded, to: notifications)
        #expect(notifications.pending.count == 1)
        #expect(notifications.pending.first?.detail == nil)
    }

    @Test(arguments: [SyncRefreshOutcome.skipped, .cancelled])
    func `skips and cancellations stay silent`(_ outcome: SyncRefreshOutcome) {
        let notifications = InAppNotifications()
        report(outcome, to: notifications)
        #expect(notifications.pending.isEmpty)
    }

    @Test func `playlist and guide completions queue separately`() throws {
        let notifications = InAppNotifications()
        let playlist = InAppNotifications.Subject.playlist(UUID(), name: "My playlist")
        report(.succeeded, to: notifications, subject: playlist)
        report(.failed, to: notifications)
        #expect(notifications.pending.map(\.subject) == [playlist, .guide])
        let first = try #require(notifications.pending.first)
        notifications.dismiss(first.id)
        let second = try #require(notifications.pending.first)
        notifications.dismiss(first.id)
        #expect(notifications.pending.first == second, "An expired old timer cannot consume the next toast")
    }

    @Test func `suspended app keeps only the latest result for a source`() {
        let notifications = InAppNotifications()
        report(.failed, to: notifications)
        report(.succeeded, to: notifications)
        #expect(notifications.pending.count == 1)
        #expect(notifications.pending.first?.outcome == .succeeded)
    }

    @Test func `inactive presentation leaves completion queued until the app returns`() {
        let notifications = InAppNotifications()
        let host = UUID()
        notifications.registerHost(host, priority: 0)
        report(.succeeded, to: notifications)
        #expect(notifications.notice(for: host, profileToken: "profile-a", isActive: false) == nil)
        #expect(notifications.pending.count == 1)
        #expect(notifications.notice(for: host, profileToken: "profile-a", isActive: true) == notifications.pending.first)
        #expect(notifications.notice(for: host, profileToken: "profile-b", isActive: true) == nil)
        #expect(notifications.notice(for: UUID(), profileToken: "profile-a", isActive: true) == nil)
    }

    @Test func `profile switch drops old completions and rejects old in-flight work`() {
        let notifications = InAppNotifications()
        report(.succeeded, to: notifications)
        notifications.retainProfile("profile-b")
        #expect(notifications.pending.isEmpty)
        report(.failed, to: notifications, current: "profile-b")
        #expect(notifications.pending.isEmpty)
        report(.succeeded, to: notifications, started: "profile-b", current: "profile-b")
        #expect(notifications.pending.count == 1)
    }

    @Test func `sheets and covers own the toast without duplicates and return it to the root`() {
        let notifications = InAppNotifications()
        let root = UUID(), settings = UUID(), progress = UUID()
        // Parent appearance can follow child appearance; explicit priorities
        // keep it from stealing the sheet's presentation in either order.
        notifications.registerHost(settings, priority: 1)
        notifications.registerHost(root, priority: 0)
        #expect(notifications.presenterID == settings)
        notifications.registerHost(progress, priority: 2)
        #expect(notifications.presenterID == progress)
        notifications.registerHost(progress, priority: 2)
        notifications.unregisterHost(progress)
        #expect(notifications.presenterID == settings)
        notifications.unregisterHost(settings)
        #expect(notifications.presenterID == root)
        notifications.unregisterHost(root)
        #expect(notifications.presenterID == nil)
    }
}

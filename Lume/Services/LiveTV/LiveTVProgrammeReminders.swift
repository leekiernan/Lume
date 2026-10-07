import Foundation
import Observation

/// Device-local requests keyed by profile/channel/start, never by a guide row
/// ID that a refresh replaces. Only explicit user actions request permission.
@MainActor @Observable
final class LiveTVProgrammeReminders {
    nonisolated struct Reminder: Codable, Equatable, Identifiable {
        let id: String
        let profile: String
        let channelID: String
        let channelName: String
        let title: String
        let start: Date
        let end: Date
    }

    struct Dependencies {
        var schedule: (Reminder, Bool) async -> Bool
        var cancel: ([String]) -> Void
        var currentProfile: () -> String
    }

    static let defaultsKey = "liveTV.programmeReminders.v1"
    static let limit = 32
    static let grace: TimeInterval = 5 * 60
    private let defaults: UserDefaults
    private let dependencies: Dependencies
    private(set) var reminders: [String: Reminder]

    init(defaults: UserDefaults = .standard, dependencies: Dependencies, now: Date = .now) {
        self.defaults = defaults
        self.dependencies = dependencies
        let stored = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: Reminder].self, from: $0) } ?? [:]
        reminders = stored.filter { $0.value.end > now && now.timeIntervalSince($0.value.start) < Self.grace }
        dependencies.cancel(Array(Set(stored.keys).subtracting(reminders.keys)))
    }

    static func identity(channelID: String, start: Date, profile: String) -> String {
        "liveTV.reminder.\(profile).\(channelID).\(Int(start.timeIntervalSince1970))"
    }

    func isReminded(channelID: String, start: Date, profile: String) -> Bool {
        reminders[Self.identity(channelID: channelID, start: start, profile: profile)] != nil
    }

    func toggle(_ programme: LiveTVHubProgramme, profile: String, now: Date = .now) async {
        let id = Self.identity(channelID: programme.channel.id, start: programme.start, profile: profile)
        if reminders.removeValue(forKey: id) != nil {
            dependencies.cancel([id])
            persist()
            return
        }
        guard programme.start > now, !profile.isEmpty, profile == dependencies.currentProfile() else { return }
        guard reminders.count < Self.limit else {
            InAppNotifications.shared.message(title: String(localized: "Reminder limit reached"),
                                              detail: String(localized: "Remove a reminder before adding another."), profileToken: profile)
            return
        }
        let reminder = Reminder(id: id, profile: profile, channelID: programme.channel.id, channelName: programme.channel.name,
                                title: programme.title, start: programme.start, end: programme.end)
        reminders[id] = reminder
        persist()
        let scheduled = await dependencies.schedule(reminder, true)
        guard reminders[id] == reminder, dependencies.currentProfile() == profile else {
            dependencies.cancel([id])
            return
        }
        if !scheduled {
            InAppNotifications.shared.message(title: String(localized: "Reminder Set"),
                                              detail: String(localized: "Lume will remind you while the app is open."), profileToken: profile)
        }
    }

    /// Cancel another profile's scheduled alerts; its saved choices are retained
    /// and re-scheduled when that profile is selected again. Never prompt here.
    func activate(profile: String, now: Date = .now, canShow: (Reminder) -> Bool = { _ in true }) async {
        dependencies.cancel(reminders.values.filter { $0.profile != profile }.map(\.id))
        let hidden = reminders.values.filter { $0.profile == profile && !canShow($0) }
        for reminder in hidden {
            reminders[reminder.id] = nil
        }
        if !hidden.isEmpty {
            dependencies.cancel(hidden.map(\.id))
            persist()
        }
        for reminder in reminders.values where reminder.profile == profile && reminder.start > now {
            guard !Task.isCancelled, dependencies.currentProfile() == profile else { return }
            _ = await dependencies.schedule(reminder, false)
            if dependencies.currentProfile() != profile || reminders[reminder.id] != reminder { dependencies.cancel([reminder.id]) }
        }
    }

    /// The root scene polls this small saved set, not the EPG. The channel is
    /// checked against current visibility before showing an in-app reminder.
    func deliverDue(profile: String, now: Date = .now, canShow: (Reminder) -> Bool, notifications: InAppNotifications) {
        guard dependencies.currentProfile() == profile else { return }
        let expired = reminders.values.filter { $0.end <= now || now.timeIntervalSince($0.start) >= Self.grace }
        let due = reminders.values.filter { $0.profile == profile && $0.start <= now && $0.end > now && now.timeIntervalSince($0.start) < Self.grace }
            .sorted { $0.start < $1.start }
        let consumed = expired + due
        guard !consumed.isEmpty else { return }
        for reminder in consumed {
            reminders[reminder.id] = nil
        }
        dependencies.cancel(consumed.map(\.id))
        persist()
        for reminder in due where canShow(reminder) {
            notifications.remind(id: reminder.id, title: reminder.title, channel: reminder.channelName, profileToken: profile)
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(reminders), forKey: Self.defaultsKey)
    }
}

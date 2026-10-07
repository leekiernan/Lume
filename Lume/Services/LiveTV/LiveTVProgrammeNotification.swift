import Foundation
import UserNotifications

extension LiveTVProgrammeReminders {
    static let shared = LiveTVProgrammeReminders(dependencies: .system)
}

extension LiveTVProgrammeReminders.Dependencies {
    static var system: Self {
        Self(schedule: { reminder, requestPermission in
            #if os(tvOS)
                return false
            #else
                let center = UNUserNotificationCenter.current()
                var status = await center.notificationSettings().authorizationStatus
                if status == .notDetermined, requestPermission {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound])
                    status = await center.notificationSettings().authorizationStatus
                }
                guard LocalNotificationAuthorization.canDeliver(status), reminder.start > .now else { return false }
                do {
                    try await center.add(LiveTVProgrammeNotification.request(reminder))
                    return true
                } catch {
                    return false
                }
            #endif
        }, cancel: { ids in
            #if !os(tvOS)
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            #endif
        }, currentProfile: { ActiveProfileStore.current?.uuidString ?? "" })
    }
}

#if !os(tvOS)
    nonisolated enum LiveTVProgrammeNotification {
        static let category = "liveTV.programme"
        static let hubURL = URL(string: "lume://live-tv")!

        static func request(_ reminder: LiveTVProgrammeReminders.Reminder) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = String(localized: "Starting now on \(reminder.channelName)")
            content.sound = .default
            content.categoryIdentifier = category
            content.userInfo = ["profile": reminder.profile]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var date = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.start)
            date.calendar = calendar
            date.timeZone = calendar.timeZone
            return UNNotificationRequest(identifier: reminder.id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: false))
        }
    }
#endif

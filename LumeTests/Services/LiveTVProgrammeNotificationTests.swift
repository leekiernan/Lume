import Foundation
@testable import Lume
import Testing
import UserNotifications

struct LiveTVProgrammeNotificationTests {
    @Test func `system reminder carries profile and airing identity and fires at absolute start`() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = LiveTVProgrammeReminders.Reminder(id: "airing", profile: "profile-a", channelID: "channel",
                                                         channelName: "BBC One", title: "Programme", start: start,
                                                         end: start.addingTimeInterval(3600))
        let request = LiveTVProgrammeNotification.request(reminder)
        #expect(request.identifier == reminder.id)
        #expect(request.content.title == reminder.title)
        #expect(request.content.userInfo["profile"] as? String == reminder.profile)
        #expect(request.content.categoryIdentifier == LiveTVProgrammeNotification.category)
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(!trigger.repeats)
        #expect(trigger.dateComponents.timeZone == TimeZone(secondsFromGMT: 0))
        #expect(trigger.dateComponents.date == start)
    }

    @Test func `notification authorization policy is shared and does not deliver without permission`() {
        #expect(LocalNotificationAuthorization.canDeliver(.authorized))
        #expect(LocalNotificationAuthorization.canDeliver(.provisional))
        #expect(!LocalNotificationAuthorization.canDeliver(.denied))
        #expect(!LocalNotificationAuthorization.canDeliver(.notDetermined))
    }
}

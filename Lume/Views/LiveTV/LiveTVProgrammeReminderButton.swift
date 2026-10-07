import SwiftUI

struct LiveTVProgrammeReminderButton: View {
    let programme: LiveTVHubProgramme
    @State private var reminders = LiveTVProgrammeReminders.shared
    @AppStorage(ActiveProfileStore.key) private var profile = ""

    var body: some View {
        ReminderButton(isReminded: reminders.isReminded(channelID: programme.channel.id, start: programme.start, profile: profile),
                       action: { Task { await reminders.toggle(programme, profile: profile) } },
                       label: { label in label.frame(maxWidth: .infinity) })
            .buttonStyle(.bordered)
            .frame(width: LiveTVHubCard.width)
    }
}

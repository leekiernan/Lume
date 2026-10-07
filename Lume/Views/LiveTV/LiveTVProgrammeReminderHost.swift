import SwiftData
import SwiftUI

private struct LiveTVProgrammeReminderHost: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @State private var guide = EPGSyncService.shared
    @AppStorage(ActiveProfileStore.key) private var profile = ""

    func body(content: Content) -> some View {
        content.task(id: "\(profile)-\(scenePhase)-\(restriction.visibilityToken)-\(guide.isSyncing)-\(profiles?.isReady == true)-\(profiles?.isSwitching == true)") {
            guard profiles?.isReady == true, profiles?.isSwitching != true else { return }
            let reminders = LiveTVProgrammeReminders.shared
            await reminders.activate(profile: profile, canShow: canShow)
            guard scenePhase == .active else { return }
            do {
                while !Task.isCancelled {
                    reminders.deliverDue(profile: profile, canShow: canShow, notifications: .shared)
                    try await Task.sleep(for: .seconds(15))
                }
            } catch { /* The inactive scene stops polling; system alerts remain scheduled. */ }
        }
    }

    private func canShow(_ reminder: LiveTVProgrammeReminders.Reminder) -> Bool {
        guard let stream = LiveTVHubSelection.stream(reminder.channelID, prefix: "", restriction: restriction, in: modelContext),
              let epgID = stream.epgChannelId else { return false }
        // Do not read a partially replaced guide. On completion, validate only
        // this small saved set through the indexed channel/start lookup.
        if guide.isSyncing { return true }
        let start = reminder.start
        var descriptor = FetchDescriptor<EPGListing>(predicate: #Predicate { $0.channelId == epgID && $0.start == start })
        descriptor.fetchLimit = 4
        guard let listings = try? modelContext.fetch(descriptor) else { return true }
        return listings.contains { LiveTVTitleIndex.key($0.title) == LiveTVTitleIndex.key(reminder.title) }
    }
}

extension View {
    func liveTVProgrammeReminders() -> some View {
        modifier(LiveTVProgrammeReminderHost())
    }
}

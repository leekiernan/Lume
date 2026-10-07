import Foundation
import UserNotifications
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// One notification delegate for downloads and programme reminders.
@MainActor final class AppNotificationDelegate: NSObject {
    static let shared = AppNotificationDelegate()

    func configure() {
        #if !os(tvOS)
            UNUserNotificationCenter.current().delegate = self
        #endif
    }

    static func open(_ url: URL) {
        #if os(macOS)
            NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
            UIApplication.shared.open(url)
        #endif
    }
}

#if !os(tvOS)
    extension AppNotificationDelegate: UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter, willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            // Open scenes use the same toast lane as tvOS, not a second banner.
            completionHandler(notification.request.content.categoryIdentifier == LiveTVProgrammeNotification.category ? [] : [.banner, .list, .sound])
        }

        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let content = response.notification.request.content
            let category = content.categoryIdentifier
            let action = response.actionIdentifier
            let profile = content.userInfo["profile"] as? String
            Task { @MainActor in
                if category == LiveTVProgrammeNotification.category, action == UNNotificationDefaultActionIdentifier,
                   profile == ActiveProfileStore.current?.uuidString
                {
                    Self.open(LiveTVProgrammeNotification.hubURL)
                } else {
                    DownloadCompletionNotifications.shared.handleResponse(category: category, action: action)
                }
                completionHandler()
            }
        }
    }
#endif

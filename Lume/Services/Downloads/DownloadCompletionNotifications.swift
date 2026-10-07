import Foundation
import OSLog
import UserNotifications

/// Local alerts only: permission is requested on Download, never at launch or
/// by a background completion. Downloading does not depend on that permission.
@MainActor
final class DownloadCompletionNotifications: NSObject {
    static let shared = DownloadCompletionNotifications()

    #if !os(tvOS)
        struct Dependencies {
            var authorizationStatus: () async -> UNAuthorizationStatus
            var requestAuthorization: () async throws -> Bool
            var schedule: (UNNotificationRequest) async throws -> Void
            var openDownloads: () -> Void

            static var system: Self {
                Self(
                    authorizationStatus: { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus },
                    requestAuthorization: { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) },
                    schedule: { try await UNUserNotificationCenter.current().add($0) },
                    openDownloads: {
                        AppNotificationDelegate.open(DownloadCompletionNotification.downloadsURL)
                    }
                )
            }
        }

        private let dependencies: Dependencies
        private var permissionTask: Task<Void, Never>?

        init(dependencies: Dependencies? = nil) {
            self.dependencies = dependencies ?? .system
            super.init()
        }
    #endif

    /// Set early enough to receive taps when a notification launches the app.
    func configure() {
        #if !os(tvOS)
            AppNotificationDelegate.shared.configure()
        #endif
    }

    func prepareForDownload() {
        #if !os(tvOS)
            guard permissionTask == nil else { return }
            permissionTask = Task {
                defer { permissionTask = nil }
                guard await dependencies.authorizationStatus() == .notDetermined else { return }
                do {
                    _ = try await dependencies.requestAuthorization()
                } catch {
                    Logger.downloads.error("Download notification permission failed: \(error.localizedDescription)")
                }
            }
        #endif
    }

    /// Called only after validation and the final file move, including for
    /// transfers adopted after a background relaunch. Never for failures/recovery.
    func notifyCompleted(_ info: DownloadTaskInfo, taskID: Int) async {
        #if !os(tvOS)
            await permissionTask?.value
            let status = await dependencies.authorizationStatus()
            guard LocalNotificationAuthorization.canDeliver(status) else { return }
            do {
                try await dependencies.schedule(DownloadCompletionNotification.request(info: info, taskID: taskID))
            } catch {
                // An alert failure must not turn a usable download into a failed one.
                Logger.downloads.error("Download completion notification failed: \(error.localizedDescription)")
            }
        #endif
    }

    #if !os(tvOS)
        func handleResponse(category: String, action: String) {
            guard DownloadCompletionNotification.opensDownloads(category: category, action: action) else { return }
            dependencies.openDownloads()
        }
    #endif
}

#if !os(tvOS)
    nonisolated enum DownloadCompletionNotification {
        static let category = "download.completed"
        static let downloadsURL = URL(string: "lume://downloads")!

        static func request(info: DownloadTaskInfo, taskID: Int) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Download Complete")
            content.body = info.title
            content.sound = .default
            content.categoryIdentifier = category
            content.threadIdentifier = "downloads"
            return UNNotificationRequest(identifier: "download.completed.\(taskID)", content: content, trigger: nil)
        }

        static func opensDownloads(category: String, action: String) -> Bool {
            category == Self.category && action == UNNotificationDefaultActionIdentifier
        }
    }
#endif

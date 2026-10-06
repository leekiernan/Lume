import Foundation
@testable import Lume
import Testing
import UserNotifications

#if !os(tvOS)
    @MainActor
    struct DownloadCompletionNotificationsTests {
        private let info = DownloadTaskInfo(id: "movie-42", title: "A Film", filename: "movie-42.mp4")

        @Test func `completion is immediate and uses the persisted task title`() {
            let request = DownloadCompletionNotification.request(info: info, taskID: 42)
            #expect(request.trigger == nil)
            #expect(request.content.body == "A Film")
            #expect(!request.content.title.isEmpty)
            #expect(request.content.sound != nil)
            #expect(request.content.threadIdentifier == "downloads")
            #expect(request.content.categoryIdentifier == DownloadCompletionNotification.category)
            #expect(request.content.userInfo.isEmpty)
        }

        @Test func `repeated delivery uses the same notification identifier`() {
            let first = DownloadCompletionNotification.request(info: info, taskID: 42)
            let repeated = DownloadCompletionNotification.request(info: info, taskID: 42)
            let other = DownloadCompletionNotification.request(info: info, taskID: 43)
            #expect(first.identifier == repeated.identifier)
            #expect(first.identifier != other.identifier)
        }

        @Test func `adopted task carries its title without a catalog lookup`() throws {
            let restored = try #require(DownloadTaskInfo(taskDescription: info.taskDescription))
            #expect(DownloadCompletionNotification.request(info: restored, taskID: 42).content.body == info.title)
        }

        @Test func `download requests permission once for concurrent starts`() async {
            let probe = NotificationProbe(status: .notDetermined)
            let service = DownloadCompletionNotifications(dependencies: probe.dependencies)
            service.prepareForDownload()
            service.prepareForDownload()
            await service.notifyCompleted(info, taskID: 42)
            #expect(probe.permissionRequests == 1)
            #expect(probe.requests.count == 1)
        }

        @Test func `denied permission never blocks completion or prompts again`() async {
            let probe = NotificationProbe(status: .denied)
            let service = DownloadCompletionNotifications(dependencies: probe.dependencies)
            service.prepareForDownload()
            await service.notifyCompleted(info, taskID: 42)
            #expect(probe.permissionRequests == 0)
            #expect(probe.requests.isEmpty)
        }

        @Test func `declining the contextual permission prompt suppresses the alert`() async {
            let probe = NotificationProbe(status: .notDetermined)
            probe.grantsPermission = false
            let service = DownloadCompletionNotifications(dependencies: probe.dependencies)
            service.prepareForDownload()
            await service.notifyCompleted(info, taskID: 42)
            #expect(probe.permissionRequests == 1)
            #expect(probe.requests.isEmpty)
        }

        @Test func `background completion never requests permission`() async {
            let probe = NotificationProbe(status: .notDetermined)
            let service = DownloadCompletionNotifications(dependencies: probe.dependencies)
            await service.notifyCompleted(info, taskID: 42)
            #expect(probe.permissionRequests == 0)
            #expect(probe.requests.isEmpty)
        }

        @Test(arguments: [UNAuthorizationStatus.authorized, .provisional])
        func `background completion delivers with existing authorization`(status: UNAuthorizationStatus) async {
            let probe = NotificationProbe(status: status)
            let service = DownloadCompletionNotifications(dependencies: probe.dependencies)
            await service.notifyCompleted(info, taskID: 42)
            #expect(probe.permissionRequests == 0)
            #expect(probe.requests.count == 1)
        }

        @Test func `notification scheduling failure does not escape into the download lifecycle`() async {
            let probe = NotificationProbe(status: .authorized)
            probe.failsScheduling = true
            let service = DownloadCompletionNotifications(dependencies: probe.dependencies)
            await service.notifyCompleted(info, taskID: 42)
            #expect(probe.requests.count == 1)
        }

        @Test func `completion awaits notification scheduling before returning`() async {
            let probe = NotificationProbe(status: .authorized)
            probe.blocksScheduling = true
            let service = DownloadCompletionNotifications(dependencies: probe.dependencies)
            let delivery = Task {
                await service.notifyCompleted(info, taskID: 42)
                probe.deliveryFinished = true
            }
            await probe.waitUntilScheduled()
            #expect(!probe.deliveryFinished)
            probe.finishScheduling()
            await delivery.value
            #expect(probe.deliveryFinished)
        }

        @Test func `permission errors do not prevent background completion bookkeeping`() async {
            let probe = NotificationProbe(status: .notDetermined)
            probe.failsAuthorization = true
            let service = DownloadCompletionNotifications(dependencies: probe.dependencies)
            service.prepareForDownload()
            await service.notifyCompleted(info, taskID: 42)
            #expect(probe.permissionRequests == 1)
            #expect(probe.requests.isEmpty)
        }

        @Test func `only a completion notification tap opens Downloads`() {
            let probe = NotificationProbe(status: .authorized)
            let service = DownloadCompletionNotifications(dependencies: probe.dependencies)
            service.handleResponse(category: "unrelated", action: UNNotificationDefaultActionIdentifier)
            service.handleResponse(category: DownloadCompletionNotification.category, action: UNNotificationDismissActionIdentifier)
            #expect(probe.openCount == 0)
            service.handleResponse(category: DownloadCompletionNotification.category, action: UNNotificationDefaultActionIdentifier)
            #expect(probe.openCount == 1)
            #expect(DeepLink(url: DownloadCompletionNotification.downloadsURL) == .downloads)
        }
    }

    @MainActor
    private final class NotificationProbe {
        var status: UNAuthorizationStatus
        var grantsPermission = true
        var failsScheduling = false
        var failsAuthorization = false
        var blocksScheduling = false
        var deliveryFinished = false
        var permissionRequests = 0
        var requests: [UNNotificationRequest] = []
        var openCount = 0
        private var scheduled: CheckedContinuation<Void, Never>?
        private var delivery: CheckedContinuation<Void, Never>?

        init(status: UNAuthorizationStatus) {
            self.status = status
        }

        var dependencies: DownloadCompletionNotifications.Dependencies {
            .init(
                authorizationStatus: { self.status },
                requestAuthorization: {
                    self.permissionRequests += 1
                    if self.failsAuthorization { throw CocoaError(.fileReadUnknown) }
                    self.status = self.grantsPermission ? .authorized : .denied
                    return self.grantsPermission
                },
                schedule: {
                    self.requests.append($0)
                    if self.failsScheduling { throw CocoaError(.fileWriteUnknown) }
                    if self.blocksScheduling {
                        await withCheckedContinuation { continuation in
                            self.delivery = continuation
                            self.scheduled?.resume()
                            self.scheduled = nil
                        }
                    }
                },
                openDownloads: { self.openCount += 1 }
            )
        }

        func waitUntilScheduled() async {
            guard delivery == nil else { return }
            await withCheckedContinuation { scheduled = $0 }
        }

        func finishScheduling() {
            delivery?.resume()
            delivery = nil
        }
    }
#endif

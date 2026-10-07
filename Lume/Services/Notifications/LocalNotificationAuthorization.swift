import UserNotifications

nonisolated enum LocalNotificationAuthorization {
    static func canDeliver(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional: true
        #if os(iOS)
            case .ephemeral: true
        #endif
        case .denied, .notDetermined: false
        @unknown default: false
        }
    }
}

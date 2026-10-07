import Foundation

nonisolated extension LiveTVHubLayout {
    static var orderKey: String {
        ProfileScopedPreferences.key(baseOrderKey)
    }

    static var hiddenKey: String {
        ProfileScopedPreferences.key(baseHiddenKey)
    }
}

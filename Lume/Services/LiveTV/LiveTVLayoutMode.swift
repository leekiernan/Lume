import Foundation

/// Persisted channel layout, independent of either platform's picker/focus UI.
nonisolated enum LiveTVLayoutMode: String, CaseIterable, Identifiable {
    case list
    case guide

    static let storageKey = "lume.liveTV.layoutMode"

    var id: String {
        rawValue
    }

    var systemImage: String {
        self == .list ? "list.bullet" : "tablecells"
    }

    static func resolved(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .list
    }
}

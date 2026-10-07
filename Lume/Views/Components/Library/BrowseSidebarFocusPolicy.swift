import Foundation

/// Selection describes the displayed content; remembered focus is only a
/// fallback for an unselected hub or a row that no longer exists.
nonisolated enum BrowseSidebarFocusPolicy {
    /// Releasing an incidental native focus during landing is not a user exit.
    /// Otherwise the panel can dismiss itself before the off-screen row lands.
    struct Handoff {
        private var hasTakenFocus = false
        private var isLanding = true

        var shouldReturnToContent: Bool {
            hasTakenFocus && !isLanding
        }

        mutating func didFocusRow() {
            hasTakenFocus = true
        }

        mutating func finishLanding() {
            isLanding = false
        }
    }

    static func landingID(selectedID: String?, lastFocusedID: String?, availableIDs: [String]) -> String? {
        if let selectedID, availableIDs.contains(selectedID) { return selectedID }
        if let lastFocusedID, availableIDs.contains(lastFocusedID) { return lastFocusedID }
        return availableIDs.first
    }
}

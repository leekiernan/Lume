import Foundation

/// All Browse menus navigate rather than select persistent filters. Remembered
/// focus survives returning to a hub, but only names an existing destination.
nonisolated enum BrowseSidebarFocusPolicy {
    /// Releasing an incidental native focus during landing is not a user exit.
    /// Otherwise the panel can dismiss itself before the off-screen row lands.
    struct Handoff {
        private var hasTakenFocus = false
        private var isLanding = true

        var shouldReturnToContent: Bool {
            hasTakenFocus && !isLanding
        }

        /// An incidental visible row may take native focus before the remembered
        /// lazy row is realized. Don't let it replace the intended landing row.
        var shouldRememberFocus: Bool {
            !isLanding
        }

        mutating func didFocusRow() {
            hasTakenFocus = true
        }

        mutating func finishLanding() {
            isLanding = false
        }
    }

    static func landingID(lastFocusedID: String?, availableIDs: [String]) -> String? {
        if let lastFocusedID, availableIDs.contains(lastFocusedID) { return lastFocusedID }
        return availableIDs.first
    }
}

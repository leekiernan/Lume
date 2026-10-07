import Observation

/// One navigation-menu owner used by every area. Remembering a row restores
/// Browse's position; it does not imply a category filter is still active.
@MainActor @Observable
final class BrowseSidebarState {
    var isPresented = false
    var rememberedRowID: String?

    /// Close before navigating so a pushed page or presented sheet cannot
    /// leave Browse over the new destination. Callers only supply the action.
    func activate(rowID: String, navigate: () -> Void) {
        rememberedRowID = rowID
        isPresented = false
        navigate()
    }
}

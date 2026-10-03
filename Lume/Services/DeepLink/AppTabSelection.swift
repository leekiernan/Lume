/// The shared navigation policy for both tab layouts. Native TabView must never
/// receive an absent selection: it may visually fall back without updating the
/// binding, leaving activeOnly/IdleUnmountingTab unable to mount that page.
nonisolated struct AppTabSelection: Equatable {
    let libraryAreas: [AppArea]
    let showsSports: Bool
    let showsSettings: Bool

    init(disabledAreasRaw: String, showsSports: Bool, showsSettings: Bool) {
        libraryAreas = AppAreaSettings.enabledAreas(disabledRaw: disabledAreasRaw)
        self.showsSports = showsSports && libraryAreas.contains(.liveTV)
        self.showsSettings = showsSettings
    }

    /// Library order, not the platform's tab order (tvOS places Search first).
    /// enabledAreas guarantees a Library area, including its corrupt-data floor.
    var initialTab: AppTab {
        libraryAreas.first?.tab ?? .home
    }

    var availableTabs: [AppTab] {
        libraryAreas.map(\.tab) + (showsSports ? [.sports] : []) + [.search] + (showsSettings ? [.settings] : [])
    }

    /// User-selected Search and Settings remain valid where rendered, but are
    /// never candidates for a launch or unavailable-tab fallback.
    func resolved(_ selection: AppTab) -> AppTab {
        availableTabs.contains(selection) ? selection : initialTab
    }
}

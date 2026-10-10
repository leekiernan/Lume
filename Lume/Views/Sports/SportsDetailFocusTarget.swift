/// Only request focus on controls that the event detail actually renders.
/// Competitor-less events can have neither channels nor detail tabs, including
/// while data is loading or after a failed lookup; their summary is the fallback.
nonisolated enum SportsDetailFocusTarget<Tab: Hashable>: Hashable {
    case channel(String)
    case follow(String)
    case tab(Tab)
    case summary

    static func preferred(
        channelID: String?, teamID: String?, availableTabs: [Tab], selectedTab: Tab
    ) -> Self {
        if let channelID { return .channel(channelID) }
        if let teamID { return .follow(teamID) }
        if availableTabs.contains(selectedTab) { return .tab(selectedTab) }
        if let first = availableTabs.first { return .tab(first) }
        return .summary
    }
}

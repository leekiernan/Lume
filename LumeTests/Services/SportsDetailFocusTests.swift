@testable import Lume
import Testing

struct SportsDetailFocusTests {
    private typealias Target = SportsDetailFocusTarget<String>

    @Test func `unavailable competitorless event lands on summary`() {
        // Scheduled UFC, loading/failed detail, or a final event with no tabs:
        // none has a Watch, Follow or Timeline control to focus.
        #expect(Target.preferred(
            channelID: nil, teamID: nil, availableTabs: [], selectedTab: "timeline"
        ) == .summary)
    }

    @Test func `watch action takes priority`() {
        #expect(Target.preferred(
            channelID: "channel", teamID: "team", availableTabs: ["timeline"], selectedTab: "timeline"
        ) == .channel("channel"))
    }

    @Test func `team event without channels can still follow`() {
        #expect(Target.preferred(
            channelID: nil, teamID: "team", availableTabs: [], selectedTab: "timeline"
        ) == .follow("team"))
    }

    @Test func `selected tab is used when rendered`() {
        #expect(Target.preferred(
            channelID: nil, teamID: nil, availableTabs: ["timeline", "stats"], selectedTab: "stats"
        ) == .tab("stats"))
    }

    @Test func `absent or hidden tab falls back to first rendered tab`() {
        // Hide Scores can leave Lineup as the only tab before onAppear has
        // corrected the selected Timeline value.
        #expect(Target.preferred(
            channelID: nil, teamID: nil, availableTabs: ["lineup"], selectedTab: "timeline"
        ) == .tab("lineup"))
    }

    @Test func `disappearing actions never leave an absent tab as target`() {
        #expect(Target.preferred(
            channelID: "channel", teamID: nil, availableTabs: [], selectedTab: "timeline"
        ) == .channel("channel"))
        #expect(Target.preferred(
            channelID: nil, teamID: nil, availableTabs: ["stats"], selectedTab: "timeline"
        ) == .tab("stats"))
        #expect(Target.preferred(
            channelID: nil, teamID: nil, availableTabs: [], selectedTab: "timeline"
        ) == .summary)
    }
}

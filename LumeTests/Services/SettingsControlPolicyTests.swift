import Foundation
@testable import Lume
import Testing

struct SettingsControlPolicyTests {
    @Test(arguments: [false, true], [false, true])
    func `sports requires both switches`(liveTV: Bool, sports: Bool) {
        let state = SportsAvailability(profileID: nil, liveTVEnabled: liveTV, sportsEnabled: sports)
        #expect(state.isEnabled == (liveTV && sports))
    }

    @Test func `layout preserves stored choices and resolves missing or unknown values to list`() {
        #expect(LiveTVLayoutMode.storageKey == "lume.liveTV.layoutMode")
        #expect(LiveTVLayoutMode.resolved("guide") == .guide)
        #expect(LiveTVLayoutMode.resolved("list") == .list)
        #expect(LiveTVLayoutMode.resolved("") == .list)
        #expect(LiveTVLayoutMode.resolved("future") == .list)
    }

    @Test func `only profile identity and effective sports availability affect work`() {
        let profile = UUID()
        #expect(SportsAvailability(profileID: profile, liveTVEnabled: false, sportsEnabled: true)
            == SportsAvailability(profileID: profile, liveTVEnabled: false, sportsEnabled: false))
        #expect(SportsAvailability(profileID: profile, liveTVEnabled: true, sportsEnabled: true)
            != SportsAvailability(profileID: UUID(), liveTVEnabled: true, sportsEnabled: true))
    }
}

@testable import Lume
import Testing

struct AppTabSelectionTests {
    @Test(arguments: [false, true])
    func `TV only launch selects Live TV before either platform mounts content`(showsSettings: Bool) {
        let policy = AppTabSelection(disabledAreasRaw: "home,movies,series", showsSports: true, showsSettings: showsSettings)
        #expect(policy.initialTab == .liveTV)
        #expect(policy.resolved(.home) == .liveTV)
        #expect(policy.availableTabs.contains(policy.resolved(.home)))
    }

    @Test func `launch follows Library order rather than native tab order`() {
        let cases: [(String, AppTab)] = [("", .home), ("home", .movies), ("home,movies", .series), ("home,movies,series", .liveTV)]
        for (disabled, expected) in cases {
            let policy = AppTabSelection(disabledAreasRaw: disabled, showsSports: true, showsSettings: true)
            #expect(policy.initialTab == expected)
            #expect(policy.resolved(.home) == expected)
        }
    }

    @Test func `all valid Library configurations have a visible nonsystem launch tab`() {
        for mask in 0 ..< 16 {
            let disabled = Set(AppArea.allCases.enumerated().compactMap { index, area in
                mask & (1 << index) != 0 ? area : nil
            })
            let policy = AppTabSelection(disabledAreasRaw: AppAreaSettings.encodeDisabled(disabled), showsSports: true, showsSettings: true)
            #expect(policy.availableTabs.contains(policy.initialTab))
            #expect(policy.initialTab != .search)
            #expect(policy.initialTab != .settings)
            #expect(policy.initialTab != .sports)
        }
    }

    @Test func `profile switch repairs an absent selection while retaining valid ones`() {
        let television = AppTabSelection(disabledAreasRaw: "home,movies,series", showsSports: true, showsSettings: false)
        #expect(television.resolved(.movies) == .liveTV)
        #expect(television.resolved(.series) == .liveTV)
        #expect(television.resolved(.liveTV) == .liveTV)
        #expect(television.resolved(.sports) == .sports)
        let movies = AppTabSelection(disabledAreasRaw: "home,series,liveTV", showsSports: false, showsSettings: false)
        #expect(movies.resolved(.liveTV) == .movies)
        #expect(movies.resolved(.sports) == .movies)
    }

    @Test func `search and platform Settings are user destinations never fallbacks`() {
        let phone = AppTabSelection(disabledAreasRaw: "home,movies,series", showsSports: true, showsSettings: false)
        #expect(phone.resolved(.search) == .search)
        #expect(phone.resolved(.settings) == .liveTV)
        let television = AppTabSelection(disabledAreasRaw: "home,movies,series", showsSports: true, showsSettings: true)
        #expect(television.resolved(.settings) == .settings)
    }

    @Test func `disabling Sports repairs selection but enabling an area does not steal it`() {
        let policy = AppTabSelection(disabledAreasRaw: "home,movies,series", showsSports: false, showsSettings: true)
        #expect(policy.resolved(.sports) == .liveTV)
        let expanded = AppTabSelection(disabledAreasRaw: "", showsSports: true, showsSettings: true)
        #expect(expanded.resolved(.liveTV) == .liveTV)
        #expect(expanded.resolved(.search) == .search)
    }

    @Test func `all disabled stored areas restore a rendered Home floor`() {
        let policy = AppTabSelection(disabledAreasRaw: "home,movies,series,liveTV", showsSports: true, showsSettings: true)
        #expect(policy.libraryAreas == [.home])
        #expect(policy.initialTab == .home)
        #expect(!policy.showsSports)
        #expect(policy.resolved(.sports) == .home)
    }
}

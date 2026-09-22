import Foundation
@testable import Lume
import Testing

struct AppAreaSettingsTests {
    // MARK: - Defaults

    @Test func `everything is on by default`() {
        #expect(AppAreaSettings.enabledAreas(disabledRaw: "") == AppArea.allCases)
        for area in AppArea.allCases {
            #expect(AppAreaSettings.isEnabled(area, disabledRaw: ""))
        }
    }

    // MARK: - encode / decode

    @Test func `encode is stably ordered`() {
        #expect(AppAreaSettings.encodeDisabled([.series, .home]) == "home,series")
        #expect(AppAreaSettings.encodeDisabled([.home, .series]) == "home,series")
    }

    @Test func `decode ignores unknown tokens`() {
        #expect(AppAreaSettings.decodeDisabled("movies,bogus,liveTV") == [.movies, .liveTV])
    }

    @Test func `decode empty string`() {
        #expect(AppAreaSettings.decodeDisabled("").isEmpty)
    }

    @Test func `encode then decode round trip`() {
        let input: Set<AppArea> = [.movies, .liveTV]
        #expect(AppAreaSettings.decodeDisabled(AppAreaSettings.encodeDisabled(input)) == input)
    }

    // MARK: - Toggling

    @Test func `switching an area off removes it from the list`() {
        let raw = AppAreaSettings.settingEnabled(false, for: .liveTV, disabledRaw: "")
        #expect(!AppAreaSettings.isEnabled(.liveTV, disabledRaw: raw))
        #expect(AppAreaSettings.enabledAreas(disabledRaw: raw) == [.home, .movies, .series])
    }

    @Test func `switching an area back on restores its place`() {
        let off = AppAreaSettings.settingEnabled(false, for: .movies, disabledRaw: "")
        let restored = AppAreaSettings.settingEnabled(true, for: .movies, disabledRaw: off)
        #expect(restored.isEmpty)
        #expect(AppAreaSettings.enabledAreas(disabledRaw: restored) == AppArea.allCases)
    }

    /// The navigation has to keep something in it, so the last area standing
    /// can't be switched off.
    @Test func `the last area cannot be switched off`() {
        var raw = ""
        for area in [AppArea.movies, .series, .liveTV] {
            raw = AppAreaSettings.settingEnabled(false, for: area, disabledRaw: raw)
        }
        #expect(AppAreaSettings.enabledAreas(disabledRaw: raw) == [.home])

        let attempt = AppAreaSettings.settingEnabled(false, for: .home, disabledRaw: raw)
        #expect(attempt == raw)
        #expect(AppAreaSettings.isEnabled(.home, disabledRaw: raw))
    }

    @Test func `canDisable reports the last area as locked`() {
        var raw = ""
        for area in [AppArea.movies, .series, .liveTV] {
            raw = AppAreaSettings.settingEnabled(false, for: area, disabledRaw: raw)
        }
        #expect(!AppAreaSettings.canDisable(.home, disabledRaw: raw))
        // An already-off area is always "disableable" — the control is the way
        // back on, so it must never be greyed out.
        #expect(AppAreaSettings.canDisable(.movies, disabledRaw: raw))
    }

    /// A stored value that somehow disables everything (hand-edited defaults, a
    /// future area removed) must still leave the app navigable.
    @Test func `enabledAreas never returns empty`() {
        let all = AppAreaSettings.encodeDisabled(Set(AppArea.allCases))
        #expect(AppAreaSettings.enabledAreas(disabledRaw: all) == [.home])
    }

    // MARK: - Area mapping

    @Test func `areas map to the right surface and category type`() {
        #expect(AppArea.home.sectionSurface == .home)
        #expect(AppArea.home.categoryType == nil)

        #expect(AppArea.movies.sectionSurface == .movies)
        #expect(AppArea.movies.categoryType == .vod)

        #expect(AppArea.series.sectionSurface == .series)
        #expect(AppArea.series.categoryType == .series)

        // Live TV is browsed by category, so it has no configurable rows.
        #expect(AppArea.liveTV.sectionSurface == nil)
        #expect(AppArea.liveTV.categoryType == .live)
    }

    @Test func `every area maps to a distinct tab`() {
        let tabs = AppArea.allCases.map(\.tab)
        #expect(Set(tabs).count == tabs.count)
        #expect(!tabs.contains(.settings))
        #expect(!tabs.contains(.search))
    }

    @Test func `every area has a label and a symbol`() {
        for area in AppArea.allCases {
            #expect(!area.displayName.isEmpty)
            #expect(!area.systemImage.isEmpty)
        }
    }
}

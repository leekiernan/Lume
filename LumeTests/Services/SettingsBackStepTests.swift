@testable import Lume
import Testing

struct SettingsBackStepTests {
    private func step(
        playlist: Bool = false,
        epg: Bool = false,
        engine: Bool = false,
        language: SettingsBackStep.LanguagePane? = nil,
        areas: Bool = false
    ) -> SettingsBackStep {
        SettingsBackStep.next(
            hasPlaylist: playlist,
            showingEPGSources: epg,
            hasEngineOptions: engine,
            languagePane: language,
            showingAreaCategories: areas
        )
    }

    @Test func `a top-level panel goes back to the sidebar`() {
        #expect(step() == .toSidebar)
    }

    @Test func `each drill-in closes before reaching the sidebar`() {
        #expect(step(playlist: true) == .closePlaylist)
        #expect(step(epg: true) == .closeEPGSources)
        #expect(step(engine: true) == .closeEngineOptions)
        #expect(step(areas: true) == .closeAreaCategories)
    }

    @Test func `the language picker steps back to the list, then to the player`() {
        #expect(step(language: .add) == .closeLanguagePicker)
        #expect(step(language: .list) == .closeLanguageList)
    }
}

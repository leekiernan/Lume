import Foundation
@testable import Lume
import Testing

@MainActor
struct SectionFeedLoadKeysTests {
    @Test func `watchlist identity retains cache compatibility and separates accounts providers and surfaces`() {
        let home = keys()
        #expect(home.watchlist(.trakt, account: nil) == "watchlist-trakt-home-disconnected-catalog")
        #expect(home.watchlist(.trakt, account: "viewer") == "watchlist-trakt-home-viewer-catalog")
        #expect(home.watchlist(.trakt, account: "viewer") != home.watchlist(.simkl, account: "viewer"))
        #expect(home.watchlist(.trakt, account: "viewer") != keys(surface: .series).watchlist(.trakt, account: "viewer"))
        #expect(home.watchlist(.trakt, account: "viewer") != keys(catalog: "other").watchlist(.trakt, account: "viewer"))
    }

    @Test func `hero selection restarts loading without throwing away the list cache`() {
        let original = keys(hero: "first")
        let changed = keys(hero: "second")
        #expect(original.customCache == changed.customCache)
        #expect(original.customTask != changed.customTask)
        #expect(original.customTask == "\(original.customCache)-hero-first")
    }

    @Test func `list URLs visible membership and Trakt accounts invalidate but titles do not`() {
        let section = CustomHomeSection(title: "List", sourceURL: "https://app.trakt.tv/users/viewer/lists/favorites")
        let original = keys(sections: [section], account: "viewer")
        var renamed = section
        renamed.title = "Renamed"
        #expect(original.customCache == keys(sections: [renamed], account: "viewer").customCache)
        var edited = section
        edited.sourceURL = "https://app.trakt.tv/users/viewer/lists/other"
        #expect(original.customCache != keys(sections: [edited], account: "viewer").customCache)
        #expect(original.customCache != keys(sections: [], account: "viewer").customCache)
        #expect(original.customCache != keys(sections: [section], account: "other").customCache)
        #expect(original.customCache != keys(sections: [section], account: nil).customCache)
        #expect(keys(account: "viewer").customCache == keys(account: "other").customCache)
    }

    private func keys(surface: SectionSurface = .home, catalog: String = "catalog", hero: String = "",
                      sections: [CustomHomeSection] = [], account: String? = nil) -> SectionFeedLoadKeys
    {
        SectionFeedLoadKeys(surface: surface, catalog: catalog, sections: sections, heroSelection: hero, traktAccount: account)
    }
}

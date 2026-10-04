import SwiftUI

/// Cache identities retain their existing shape. Hero selection restarts the
/// custom lane without invalidating its list cache; a rename does neither.
struct SectionFeedLoadKeys {
    let surface: SectionSurface
    let catalog: String
    let customCache: String
    let customTask: String

    init(surface: SectionSurface, catalog: String, sections: [CustomHomeSection], heroSelection: String, traktAccount: String?) {
        self.surface = surface
        self.catalog = catalog
        customCache = "custom-\(catalog)-\(CustomHomeSections.contentSignature(sections))"
            + CustomHomeSections.accountSignature(sections, traktUsername: traktAccount)
        customTask = "\(customCache)-hero-\(heroSelection)"
    }

    func watchlist(_ provider: WatchlistProvider, account: String?) -> String {
        "watchlist-\(provider)-\(surface.rawValue)-\(account ?? "disconnected")-\(catalog)"
    }
}

/// SwiftUI task ownership shared by Home and Library surfaces. Publication,
/// stale-result rejection and scope recovery stay in SectionFeed's machines;
/// locally queried rows, recommendations and hero seeding stay with the screen.
struct SectionFeedLoadConfiguration {
    let context: SectionFeed.Context
    let catalogKey: String
    let heroRef: HomeSectionRef?
    let heroSelection: String
    let customSections: [CustomHomeSection]
    let traktAccount: String?
    let prepareCustomSections: () -> Void
}

private struct SectionFeedLoading: ViewModifier {
    let feed: SectionFeed
    let configuration: SectionFeedLoadConfiguration

    func body(content: Content) -> some View {
        let keys = SectionFeedLoadKeys(surface: feed.surface, catalog: configuration.catalogKey, sections: configuration.customSections,
                                       heroSelection: configuration.heroSelection, traktAccount: configuration.traktAccount)
        let traktKey = keys.watchlist(.trakt, account: WatchlistProvider.trakt.account)
        let simklKey = keys.watchlist(.simkl, account: WatchlistProvider.simkl.account)
        content
            .task(id: keys.catalog) {
                guard prepare() else { return }
                await feed.loadTrending(cacheKey: keys.catalog)
            }
            .task(id: traktKey) {
                guard prepare() else { return }
                await feed.loadWatchlist(.trakt, cacheKey: traktKey)
            }
            .task(id: simklKey) {
                guard prepare() else { return }
                await feed.loadWatchlist(.simkl, cacheKey: simklKey)
            }
            .task(id: keys.customTask) {
                guard !Task.isCancelled else { return }
                configuration.prepareCustomSections()
                guard prepare() else { return }
                await feed.loadCustomSections(cacheKey: keys.customCache, sections: configuration.customSections)
            }
    }

    private func prepare() -> Bool {
        guard !Task.isCancelled else { return false }
        feed.heroRef = configuration.heroRef
        feed.update(context: configuration.context)
        return true
    }
}

extension View {
    func sectionFeedLoads(feed: SectionFeed, configuration: SectionFeedLoadConfiguration) -> some View {
        modifier(SectionFeedLoading(feed: feed, configuration: configuration))
    }
}

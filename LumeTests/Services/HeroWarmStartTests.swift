import Foundation
@testable import Lume
import Testing

struct HeroWarmStartTests {
    private static let alpha = CustomHomeSection(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        title: "Popular Movies",
        sourceURL: "https://mdblist.com/lists/official/movies/popular"
    )
    private static let beta = CustomHomeSection(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
        title: "Popular Shows",
        sourceURL: "https://mdblist.com/lists/official/shows/popular"
    )

    @Test func `hero warm start round trips for the same hero and catalog`() throws {
        let hero = HomeSectionRef.custom(Self.alpha.id)
        let backdrop = try #require(URL(string: "https://image.tmdb.org/t/p/original/backdrop.jpg"))
        let encoded = try #require(HeroWarmStartCache.encode(
            hero: hero,
            catalogScope: "playlist-a",
            backdropURL: backdrop
        ))

        #expect(HeroWarmStartCache.backdropURL(
            from: encoded,
            hero: hero,
            catalogScope: "playlist-a"
        ) == backdrop)
    }

    @Test func `hero warm start rejects a different hero or catalog`() throws {
        let hero = HomeSectionRef.custom(Self.alpha.id)
        let backdrop = try #require(URL(string: "https://image.tmdb.org/t/p/original/backdrop.jpg"))
        let encoded = try #require(HeroWarmStartCache.encode(
            hero: hero,
            catalogScope: "playlist-a",
            backdropURL: backdrop
        ))

        #expect(HeroWarmStartCache.backdropURL(
            from: encoded,
            hero: .custom(Self.beta.id),
            catalogScope: "playlist-a"
        ) == nil)
        #expect(HeroWarmStartCache.backdropURL(
            from: encoded,
            hero: hero,
            catalogScope: "playlist-b"
        ) == nil)
        #expect(HeroWarmStartCache.backdropURL(
            from: encoded,
            hero: nil,
            catalogScope: "playlist-a"
        ) == nil)
    }

    @Test func `hero warm start scope changes with restrictions and edited source`() {
        let playlistID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        let hero = HomeSectionRef.custom(Self.alpha.id)
        let original = HeroWarmStartCache.catalogScope(
            playlistID: playlistID,
            visibilityToken: "visible-a",
            hero: hero,
            customSections: [Self.alpha]
        )
        let restricted = HeroWarmStartCache.catalogScope(
            playlistID: playlistID,
            visibilityToken: "visible-b",
            hero: hero,
            customSections: [Self.alpha]
        )
        var edited = Self.alpha
        edited.sourceURL = "https://mdblist.com/lists/official/movies/top-rated"
        let changedSource = HeroWarmStartCache.catalogScope(
            playlistID: playlistID,
            visibilityToken: "visible-a",
            hero: hero,
            customSections: [edited]
        )

        #expect(original != restricted)
        #expect(original != changedSource)
    }

    @Test @MainActor func `configured hero releases its slot after resolving empty`() async {
        let feed = SectionFeed(surface: .home)
        feed.heroRef = .custom(Self.alpha.id)

        #expect(feed.heroState == .loading)
        #expect(feed.heroState.reservesSpace)

        await feed.loadCustomSections(cacheKey: "empty", sections: [])

        #expect(feed.heroState == .empty)
        #expect(!feed.heroState.reservesSpace)
    }

    @Test func `malformed hero warm start is ignored`() {
        #expect(HeroWarmStartCache.backdropURL(
            from: "not-json",
            hero: .custom(Self.alpha.id),
            catalogScope: "playlist-a"
        ) == nil)
    }
}

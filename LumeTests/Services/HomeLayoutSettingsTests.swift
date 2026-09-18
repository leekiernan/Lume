import Foundation
@testable import Lume
import Testing

struct HomeLayoutSettingsTests {
    /// Two custom rows to interleave with the built-in ones.
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

    private var builtins: [HomeSectionRef] {
        HomeSection.cases(for: .home).map(HomeSectionRef.builtin)
    }

    // MARK: - encode / decode

    @Test func `encode single section`() {
        let result = HomeLayoutSettings.encode([.builtin(.recentlyWatched)])
        #expect(result == "recentlyWatched")
    }

    @Test func `encode multiple sections`() {
        let result = HomeLayoutSettings.encode([.builtin(.favorites), .builtin(.forYou)])
        #expect(result == "favorites,forYou")
    }

    @Test func `encode custom section uses a prefixed token`() {
        let result = HomeLayoutSettings.encode([.custom(Self.alpha.id)])
        #expect(result == "custom:\(Self.alpha.id.uuidString)")
    }

    @Test func `decode single section`() {
        let result = HomeLayoutSettings.decode("recentlyWatched")
        #expect(result == [.builtin(.recentlyWatched)])
    }

    @Test func `decode multiple sections`() {
        let result = HomeLayoutSettings.decode("favorites,forYou")
        #expect(result == [.builtin(.favorites), .builtin(.forYou)])
    }

    @Test func `decode mixes custom and built-in tokens`() {
        let raw = "favorites,custom:\(Self.alpha.id.uuidString),forYou"
        #expect(HomeLayoutSettings.decode(raw) == [
            .builtin(.favorites), .custom(Self.alpha.id), .builtin(.forYou)
        ])
    }

    @Test func `decode unknown tokens are dropped`() {
        let result = HomeLayoutSettings.decode("favorites,bogus,recentlyWatched")
        #expect(result == [.builtin(.favorites), .builtin(.recentlyWatched)])
    }

    @Test func `decode drops a custom token with a malformed id`() {
        #expect(HomeLayoutSettings.decode("custom:not-a-uuid,favorites") == [.builtin(.favorites)])
    }

    @Test func `decode empty string`() {
        let result = HomeLayoutSettings.decode("")
        #expect(result.isEmpty)
    }

    @Test func `encode then decode round trip`() {
        let input: [HomeSectionRef] = [
            .builtin(.recentlyWatched), .custom(Self.alpha.id), .builtin(.favorites),
            .builtin(.forYou), .builtin(.trendingMovies), .builtin(.trendingSeries),
            .builtin(.traktWatchlist), .custom(Self.beta.id)
        ]
        let encoded = HomeLayoutSettings.encode(input)
        let decoded = HomeLayoutSettings.decode(encoded)
        #expect(decoded == input)
    }

    // MARK: - normalized

    @Test func `normalized keeps given order and appends missing`() {
        let result = HomeLayoutSettings.normalized(
            [.builtin(.forYou), .builtin(.recentlyWatched)], custom: [], surface: .home
        )
        #expect(result.first == .builtin(.forYou))
        #expect(result[1] == .builtin(.recentlyWatched))
        for section in HomeSection.cases(for: .home) {
            #expect(result.contains(.builtin(section)))
        }
    }

    @Test func `normalized deduplicates`() {
        let result = HomeLayoutSettings.normalized(
            [.builtin(.favorites), .builtin(.favorites), .builtin(.forYou), .builtin(.favorites)],
            custom: [], surface: .home
        )
        let favoritesCount = result.count(where: { $0 == .builtin(.favorites) })
        #expect(favoritesCount == 1)
    }

    @Test func `normalized empty input falls back to all sections`() {
        let result = HomeLayoutSettings.normalized([], custom: [], surface: .home)
        #expect(result == builtins)
    }

    @Test func `normalized handles partial list`() {
        let result = HomeLayoutSettings.normalized(
            [.builtin(.traktWatchlist), .builtin(.trendingMovies)], custom: [], surface: .home
        )
        #expect(result.first == .builtin(.traktWatchlist))
        #expect(result[1] == .builtin(.trendingMovies))
        #expect(result.count == HomeSection.cases(for: .home).count)
    }

    @Test func `normalized appends a newly added custom section at the end`() {
        let result = HomeLayoutSettings.normalized(builtins, custom: [Self.alpha, Self.beta], surface: .home)
        #expect(result.suffix(2) == [.custom(Self.alpha.id), .custom(Self.beta.id)])
    }

    @Test func `normalized keeps a custom section where the user placed it`() {
        let order: [HomeSectionRef] = [.custom(Self.alpha.id), .builtin(.favorites)]
        let result = HomeLayoutSettings.normalized(order, custom: [Self.alpha], surface: .home)
        #expect(result.first == .custom(Self.alpha.id))
        #expect(result[1] == .builtin(.favorites))
        #expect(result.count == HomeSection.cases(for: .home).count + 1)
    }

    /// A section deleted on another device leaves its token behind in the synced
    /// order; it must not survive as a phantom row.
    @Test func `normalized drops a custom ref with no matching section`() {
        let order: [HomeSectionRef] = [.custom(Self.alpha.id), .builtin(.favorites)]
        let result = HomeLayoutSettings.normalized(order, custom: [], surface: .home)
        #expect(!result.contains(.custom(Self.alpha.id)))
        #expect(result.first == .builtin(.favorites))
    }

    // MARK: - resolve

    @Test func `resolve with stored order uses it`() {
        let result = HomeLayoutSettings.resolve(orderRaw: "favorites,forYou", custom: [], surface: .home)
        #expect(result.first == .builtin(.favorites))
        #expect(result[1] == .builtin(.forYou))
    }

    @Test func `resolve with empty string falls back to all sections`() {
        let result = HomeLayoutSettings.resolve(orderRaw: "", custom: [], surface: .home)
        #expect(result == builtins)
    }

    @Test func `resolve appends custom sections when nothing is stored`() {
        let result = HomeLayoutSettings.resolve(orderRaw: "", custom: [Self.alpha], surface: .home)
        #expect(result == builtins + [.custom(Self.alpha.id)])
    }

    // MARK: - encodeDisabled / decodeDisabled

    @Test func `encodeDisabled single section`() {
        let result = HomeLayoutSettings.encodeDisabled([.builtin(.trendingMovies)])
        #expect(result == "trendingMovies")
    }

    @Test func `encodeDisabled multiple sections sorted`() {
        let result = HomeLayoutSettings.encodeDisabled([.builtin(.forYou), .builtin(.favorites)])
        #expect(result == "favorites,forYou")
    }

    @Test func `decodeDisabled single section`() {
        let result = HomeLayoutSettings.decodeDisabled("favorites")
        #expect(result == [.builtin(.favorites)])
    }

    @Test func `decodeDisabled multiple sections`() {
        let result = HomeLayoutSettings.decodeDisabled("favorites,forYou")
        #expect(result == [.builtin(.favorites), .builtin(.forYou)])
    }

    @Test func `decodeDisabled empty string`() {
        let result = HomeLayoutSettings.decodeDisabled("")
        #expect(result.isEmpty)
    }

    @Test func `decodeDisabled ignores unknown sections`() {
        let result = HomeLayoutSettings.decodeDisabled("favorites,bogus,forYou")
        #expect(result == [.builtin(.favorites), .builtin(.forYou)])
    }

    @Test func `encode then decode disabled round trip`() {
        let input: Set<HomeSectionRef> = [
            .builtin(.favorites), .builtin(.trendingMovies), .builtin(.traktWatchlist),
            .custom(Self.alpha.id)
        ]
        let encoded = HomeLayoutSettings.encodeDisabled(input)
        let decoded = HomeLayoutSettings.decodeDisabled(encoded)
        #expect(decoded == input)
    }

    // MARK: - isEnabled

    @Test func `isEnabled returns true for sections not in disabled set`() {
        #expect(HomeLayoutSettings.isEnabled(.builtin(.recentlyWatched), disabledRaw: ""))
        #expect(HomeLayoutSettings.isEnabled(.builtin(.recentlyWatched), disabledRaw: "favorites"))
    }

    @Test func `isEnabled returns false for disabled section`() {
        #expect(!HomeLayoutSettings.isEnabled(.builtin(.favorites), disabledRaw: "favorites,forYou"))
    }

    @Test func `isEnabled tracks a hidden custom section`() {
        let raw = HomeLayoutSettings.settingEnabled(false, for: .custom(Self.alpha.id), disabledRaw: "")
        #expect(!HomeLayoutSettings.isEnabled(.custom(Self.alpha.id), disabledRaw: raw))
        #expect(HomeLayoutSettings.isEnabled(.custom(Self.beta.id), disabledRaw: raw))
    }

    @Test func `settingEnabled clears a hidden row`() {
        let hidden = HomeLayoutSettings.settingEnabled(false, for: .builtin(.favorites), disabledRaw: "")
        let shown = HomeLayoutSettings.settingEnabled(true, for: .builtin(.favorites), disabledRaw: hidden)
        #expect(shown.isEmpty)
    }

    // MARK: - HomeSection properties

    @Test func `home section all cases are unique`() {
        let ids = HomeSection.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func `home section has non empty system images`() {
        for section in HomeSection.allCases {
            #expect(!section.systemImage.isEmpty)
        }
    }

    // MARK: - Hero

    /// Only rows the shared feed resolves from a list can be the hero; the
    /// @Query-backed local rows are assembled by each page, so the feed never
    /// sees their items.
    @Test func `only list-backed rows are promotable`() {
        #expect(HomeSection.trendingMovies.isPromotable)
        #expect(HomeSection.trendingSeries.isPromotable)
        #expect(HomeSection.traktWatchlist.isPromotable)

        #expect(!HomeSection.recentlyWatched.isPromotable)
        #expect(!HomeSection.favorites.isPromotable)
        #expect(!HomeSection.recentlyAdded.isPromotable)
        #expect(!HomeSection.forYou.isPromotable)
    }

    /// A custom row is a list by definition, so it always qualifies.
    @Test func `custom rows are always promotable`() {
        #expect(HomeSectionRef.custom(Self.alpha.id).isPromotable)
        #expect(HomeSectionRef.builtin(.trendingMovies).isPromotable)
        #expect(!HomeSectionRef.builtin(.favorites).isPromotable)
    }

    /// The designation is a section token, so it can name a built-in row or a
    /// custom one, and round-trips through storage.
    @Test func `the hero designation round trips`() {
        for ref in [HomeSectionRef.custom(Self.alpha.id), .builtin(.trendingMovies)] {
            #expect(HomeLayoutSettings.heroRef(ref.token) == ref)
        }
        #expect(HomeLayoutSettings.heroRef("") == nil)
        #expect(HomeLayoutSettings.heroRef("nonsense") == nil)
    }

    // MARK: - The starting hero

    /// A fresh surface gets its hero as an ordinary section holding a real URL —
    /// editable, demotable and deletable like any other.
    @Test func `a fresh surface is seeded with a hero`() throws {
        for surface in SectionSurface.allCases {
            let outcome = CustomHomeSections.seedingDefaultHero(
                surface: surface, sections: [], heroRaw: "", orderRaw: "", seeded: false
            )
            guard case let .seed(sections, heroToken, _) = outcome else {
                Issue.record("\(surface) was not seeded"); continue
            }
            let seeded = (sections: sections, heroToken: heroToken)
            let section = try #require(seeded.sections.first)
            #expect(seeded.sections.count == 1)
            #expect(section.sourceURL == surface.defaultHeroSourceURL)
            #expect(!section.sourceURL.isEmpty)
            #expect(seeded.heroToken == HomeSectionRef.custom(section.id).token)
            // The URL has to be one a provider can actually read.
            #expect(HomeListCatalog.provider(for: section.sourceURL)?.displayName == "TMDB")
        }
    }

    /// It leads the list, so the settings screen opens on the hero rather than
    /// burying it under every built-in row — and a new user can see, and change,
    /// where their hero comes from on the first visit.
    @Test func `the seeded hero leads the order`() throws {
        guard case let .seed(sections, _, orderRaw) = CustomHomeSections.seedingDefaultHero(
            surface: .movies, sections: [], heroRaw: "", orderRaw: "", seeded: false
        ) else { Issue.record("expected a seed"); return }
        let section = try #require(sections.first)
        let order = HomeLayoutSettings.decode(orderRaw)
        #expect(order.first == .custom(section.id))
    }

    /// Seeding into an existing layout keeps that order, just with the hero in
    /// front of it.
    @Test func `seeding preserves an order the user already set`() {
        let existing = HomeLayoutSettings.encode([.builtin(.favorites), .builtin(.recentlyWatched)])
        guard case let .seed(_, _, orderRaw) = CustomHomeSections.seedingDefaultHero(
            surface: .movies, sections: [], heroRaw: "", orderRaw: existing, seeded: false
        ) else { Issue.record("expected a seed"); return }
        let order = HomeLayoutSettings.decode(orderRaw)
        #expect(order.dropFirst().prefix(2) == [.builtin(.favorites), .builtin(.recentlyWatched)])
    }

    /// Home mixes media and a section carries one URL, so its default is the
    /// feed whose rows name their own medium.
    @Test func `each surface seeds the right feed`() {
        #expect(SectionSurface.home.defaultHeroSourceURL.contains("trending/all"))
        #expect(SectionSurface.movies.defaultHeroSourceURL.contains("trending/movie"))
        #expect(SectionSurface.series.defaultHeroSourceURL.contains("trending/tv"))
    }

    /// Deleting the starting hero has to stick — seeding runs once, not on
    /// every launch.
    @Test func `seeding does not run twice`() {
        #expect(CustomHomeSections.seedingDefaultHero(
            surface: .home, sections: [], heroRaw: "", orderRaw: "", seeded: true
        ).isSeed == false)
    }

    /// Someone who removes their hero keeps it removed. Seeding is for a first
    /// install, not a default that reasserts itself.
    @Test func `removing the hero does not bring one back`() {
        let outcome = CustomHomeSections.seedingDefaultHero(
            surface: .home, sections: [], heroRaw: "", orderRaw: "", seeded: true
        )
        #expect(!outcome.isSeed)
    }

    /// A hero token an older build wrote in a different format — a bare UUID,
    /// before the designation could also name a built-in row — resolves to
    /// nothing. That has to count as "no hero" and seed, or the surface is left
    /// with neither a hero nor the row that would restore one.
    @Test func `an unreadable hero token seeds anyway`() {
        let legacy = UUID().uuidString
        #expect(HomeLayoutSettings.heroRef(legacy) == nil)
        let outcome = CustomHomeSections.seedingDefaultHero(
            surface: .home, sections: [], heroRaw: legacy, orderRaw: "", seeded: false
        )
        guard case let .seed(_, heroToken, _) = outcome else {
            Issue.record("expected a seed"); return
        }
        #expect(heroToken != legacy)
    }

    /// Likewise a token naming a section that has since been deleted.
    @Test func `a hero naming a missing section seeds anyway`() {
        let token = HomeSectionRef.custom(Self.alpha.id).token
        #expect(!CustomHomeSections.heroResolves(token, sections: [], surface: .home))
        #expect(CustomHomeSections.seedingDefaultHero(
            surface: .home, sections: [], heroRaw: token, orderRaw: "", seeded: false
        ).isSeed)
    }

    /// A promoted built-in row is a perfectly good hero, so it blocks seeding.
    @Test func `a promoted built-in row counts as a hero`() {
        let token = HomeSectionRef.builtin(.trendingMovies).token
        #expect(CustomHomeSections.heroResolves(token, sections: [], surface: .movies))
        // ...but not one this surface doesn't offer.
        #expect(!CustomHomeSections.heroResolves(token, sections: [], surface: .series))
        // ...nor one the feed can't build a hero from.
        #expect(!CustomHomeSections.heroResolves(
            HomeSectionRef.builtin(.favorites).token, sections: [], surface: .movies
        ))
    }

    /// Nor does it run when the surface already has a hero.
    @Test func `seeding leaves an existing hero alone`() {
        let outcome = CustomHomeSections.seedingDefaultHero(
            surface: .home,
            sections: [Self.alpha],
            heroRaw: HomeSectionRef.custom(Self.alpha.id).token,
            orderRaw: "",
            seeded: false
        )
        // Reported so the caller can record it: a surface that already has a
        // hero has had one, and removing it later must not bring a new one back.
        #expect(!outcome.isSeed)
        if case .alreadyHasHero = outcome {} else { Issue.record("expected alreadyHasHero") }
    }

    // MARK: - Surfaces

    /// Each page offers the rows that make sense there: Home mixes both media
    /// and owns the recommendations row, while Movies and Series each take only
    /// their own trending row.
    @Test func `each surface offers its own built-in rows`() {
        #expect(HomeSection.cases(for: .home).contains(.forYou))
        #expect(HomeSection.cases(for: .home).contains(.trendingMovies))
        #expect(HomeSection.cases(for: .home).contains(.trendingSeries))

        #expect(!HomeSection.cases(for: .movies).contains(.forYou))
        #expect(HomeSection.cases(for: .movies).contains(.trendingMovies))
        #expect(!HomeSection.cases(for: .movies).contains(.trendingSeries))

        #expect(!HomeSection.cases(for: .series).contains(.forYou))
        #expect(HomeSection.cases(for: .series).contains(.trendingSeries))
        #expect(!HomeSection.cases(for: .series).contains(.trendingMovies))
    }

    @Test func `recently added is a library row, not a Home one`() {
        #expect(!HomeSection.cases(for: .home).contains(.recentlyAdded))
        #expect(HomeSection.cases(for: .movies).contains(.recentlyAdded))
        #expect(HomeSection.cases(for: .series).contains(.recentlyAdded))
    }

    @Test func `resolve returns the surface default order`() {
        for surface in SectionSurface.allCases {
            let result = HomeLayoutSettings.resolve(orderRaw: "", custom: [], surface: surface)
            #expect(result == HomeSection.cases(for: surface).map(HomeSectionRef.builtin))
        }
    }

    /// A stored order carrying a row from another page (synced across devices,
    /// or left over from an older build) must not conjure that row here.
    @Test func `normalized drops built-ins that do not belong to the surface`() {
        let order: [HomeSectionRef] = [.builtin(.forYou), .builtin(.trendingSeries), .builtin(.favorites)]
        let result = HomeLayoutSettings.normalized(order, custom: [], surface: .movies)
        #expect(!result.contains(.builtin(.forYou)))
        #expect(!result.contains(.builtin(.trendingSeries)))
        #expect(result.first == .builtin(.favorites))
        #expect(result.count == HomeSection.cases(for: .movies).count)
    }

    @Test func `each surface stores its layout under its own keys`() {
        let orderKeys = SectionSurface.allCases.map(HomeLayoutSettings.sectionOrderKey)
        let hiddenKeys = SectionSurface.allCases.map(HomeLayoutSettings.disabledSectionsKey)
        let customKeys = SectionSurface.allCases.map(CustomHomeSections.storageKey)
        let all = orderKeys + hiddenKeys + customKeys
        #expect(Set(all).count == all.count)
    }

    /// Home shipped before the other surfaces existed, so its keys must not move
    /// — a rename would silently reset everyone's Home layout.
    @Test func `home keeps the keys it shipped with`() {
        #expect(HomeLayoutSettings.sectionOrderKey(.home) == "home.sectionOrder.v1")
        #expect(HomeLayoutSettings.disabledSectionsKey(.home) == "home.disabledSections.v1")
        #expect(CustomHomeSections.storageKey(.home) == "home.customSections.v1")
    }

    /// What makes a movie list on the Series page resolve to nothing.
    @Test func `surfaces narrow to one medium`() {
        #expect(SectionSurface.home.mediaType == nil)
        #expect(SectionSurface.movies.mediaType == .movie)
        #expect(SectionSurface.series.mediaType == .series)
    }

    /// The custom prefix must never be mistakable for a built-in raw value.
    @Test func `built-in raw values never look like custom tokens`() {
        for section in HomeSection.allCases {
            #expect(!section.rawValue.contains(":"))
            #expect(HomeSectionRef(token: section.rawValue) == .builtin(section))
        }
    }
}

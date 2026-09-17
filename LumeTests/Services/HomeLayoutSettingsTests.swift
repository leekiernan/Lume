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
        HomeSection.allCases.map(HomeSectionRef.builtin)
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
            [.builtin(.forYou), .builtin(.recentlyWatched)], custom: []
        )
        #expect(result.first == .builtin(.forYou))
        #expect(result[1] == .builtin(.recentlyWatched))
        for section in HomeSection.allCases {
            #expect(result.contains(.builtin(section)))
        }
    }

    @Test func `normalized deduplicates`() {
        let result = HomeLayoutSettings.normalized(
            [.builtin(.favorites), .builtin(.favorites), .builtin(.forYou), .builtin(.favorites)],
            custom: []
        )
        let favoritesCount = result.count(where: { $0 == .builtin(.favorites) })
        #expect(favoritesCount == 1)
    }

    @Test func `normalized empty input falls back to all sections`() {
        let result = HomeLayoutSettings.normalized([], custom: [])
        #expect(result == builtins)
    }

    @Test func `normalized handles partial list`() {
        let result = HomeLayoutSettings.normalized(
            [.builtin(.traktWatchlist), .builtin(.trendingMovies)], custom: []
        )
        #expect(result.first == .builtin(.traktWatchlist))
        #expect(result[1] == .builtin(.trendingMovies))
        #expect(result.count == HomeSection.allCases.count)
    }

    @Test func `normalized appends a newly added custom section at the end`() {
        let result = HomeLayoutSettings.normalized(builtins, custom: [Self.alpha, Self.beta])
        #expect(result.suffix(2) == [.custom(Self.alpha.id), .custom(Self.beta.id)])
    }

    @Test func `normalized keeps a custom section where the user placed it`() {
        let order: [HomeSectionRef] = [.custom(Self.alpha.id), .builtin(.favorites)]
        let result = HomeLayoutSettings.normalized(order, custom: [Self.alpha])
        #expect(result.first == .custom(Self.alpha.id))
        #expect(result[1] == .builtin(.favorites))
        #expect(result.count == HomeSection.allCases.count + 1)
    }

    /// A section deleted on another device leaves its token behind in the synced
    /// order; it must not survive as a phantom row.
    @Test func `normalized drops a custom ref with no matching section`() {
        let order: [HomeSectionRef] = [.custom(Self.alpha.id), .builtin(.favorites)]
        let result = HomeLayoutSettings.normalized(order, custom: [])
        #expect(!result.contains(.custom(Self.alpha.id)))
        #expect(result.first == .builtin(.favorites))
    }

    // MARK: - resolve

    @Test func `resolve with stored order uses it`() {
        let result = HomeLayoutSettings.resolve(orderRaw: "favorites,forYou", custom: [])
        #expect(result.first == .builtin(.favorites))
        #expect(result[1] == .builtin(.forYou))
    }

    @Test func `resolve with empty string falls back to all sections`() {
        let result = HomeLayoutSettings.resolve(orderRaw: "", custom: [])
        #expect(result == builtins)
    }

    @Test func `resolve appends custom sections when nothing is stored`() {
        let result = HomeLayoutSettings.resolve(orderRaw: "", custom: [Self.alpha])
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

    /// The custom prefix must never be mistakable for a built-in raw value.
    @Test func `built-in raw values never look like custom tokens`() {
        for section in HomeSection.allCases {
            #expect(!section.rawValue.contains(":"))
            #expect(HomeSectionRef(token: section.rawValue) == .builtin(section))
        }
    }
}

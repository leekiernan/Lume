import Foundation
@testable import Lume
import Testing

struct TraktListProviderTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    /// A provider whose client has credentials and answers from the stub.
    private func stubbedProvider() -> TraktListProvider {
        TraktListProvider(client: TraktClient(
            session: StubURLProtocol.makeSession(),
            clientID: "test-client",
            clientSecret: "test-secret"
        ))
    }

    // MARK: - canHandle

    @Test func `claims trakt hosts`() throws {
        let provider = TraktListProvider()
        #expect(try provider.canHandle(url("https://trakt.tv/users/alice/lists/favs")))
        #expect(try provider.canHandle(url("https://www.trakt.tv/users/alice/lists/favs")))
        #expect(try provider.canHandle(url("https://app.trakt.tv/users/alice/lists/favs")))
        #expect(try provider.canHandle(url("https://api.trakt.tv/users/alice/lists/favs/items")))
    }

    @Test func `ignores other hosts`() throws {
        let provider = TraktListProvider()
        #expect(try !provider.canHandle(url("https://example.com/users/alice/lists/favs")))
        #expect(try !provider.canHandle(url("https://nottrakt.tv/users/alice/lists/favs")))
    }

    // MARK: - URL shaping

    /// The page the user sees on the new web app, display settings and all.
    @Test func `maps a web app list page to its items endpoint`() throws {
        let list = try TraktListProvider.list(for: url("https://app.trakt.tv/users/kiernan/lists/classic-rewatch?mode=media"))
        #expect(list == TraktListProvider.ListReference(owner: "kiernan", id: "classic-rewatch"))
        #expect(list?.itemsPath == "users/kiernan/lists/classic-rewatch/items")
    }

    @Test func `maps a classic site list page`() throws {
        let list = try TraktListProvider.list(for: url("https://trakt.tv/users/alice/lists/favs?sort=rank,asc#top"))
        #expect(list?.itemsPath == "users/alice/lists/favs/items")
    }

    @Test func `maps a list shared by id`() throws {
        let list = try TraktListProvider.list(for: url("https://trakt.tv/lists/5308818"))
        #expect(list == TraktListProvider.ListReference(owner: nil, id: "5308818"))
        #expect(list?.itemsPath == "lists/5308818/items")
    }

    /// Idempotent for an API URL, with or without its `/items` suffix.
    @Test func `accepts an API URL as the list it already names`() throws {
        let withItems = try TraktListProvider.list(for: url("https://api.trakt.tv/users/alice/lists/favs/items/movie"))
        let bare = try TraktListProvider.list(for: url("https://api.trakt.tv/users/alice/lists/favs"))
        #expect(withItems?.itemsPath == "users/alice/lists/favs/items")
        #expect(bare?.itemsPath == "users/alice/lists/favs/items")
    }

    /// Path keywords match in any case; the owner and slug are passed through.
    @Test func `keeps the owner and slug as typed`() throws {
        let list = try TraktListProvider.list(for: url("https://trakt.tv/Users/Alice/Lists/Favs"))
        #expect(list?.itemsPath == "users/Alice/lists/Favs/items")
    }

    @Test func `percent-encodes a username the path cannot carry raw`() {
        let list = TraktListProvider.ListReference(owner: "a b", id: "favs")
        #expect(list.itemsPath == "users/a%20b/lists/favs/items")
    }

    @Test func `rejects a URL that is not a list`() throws {
        #expect(try TraktListProvider.list(for: url("https://trakt.tv/")) == nil)
        #expect(try TraktListProvider.list(for: url("https://trakt.tv/users/alice")) == nil)
        #expect(try TraktListProvider.list(for: url("https://trakt.tv/users/alice/lists")) == nil)
        #expect(try TraktListProvider.list(for: url("https://trakt.tv/movies/the-matrix-1999")) == nil)
        #expect(try TraktListProvider.list(for: url("https://trakt.tv/lists")) == nil)
    }

    // MARK: - suggestedTitle

    @Test func `suggests a title from the list slug`() throws {
        let provider = TraktListProvider()
        #expect(try provider.suggestedTitle(for: url("https://app.trakt.tv/users/kiernan/lists/classic-rewatch?mode=media")) == "Classic Rewatch")
        #expect(try provider.suggestedTitle(for: url("https://trakt.tv/users/alice/lists/top_picks")) == "Top Picks")
    }

    @Test func `falls back to a generic title for a list shared by id`() throws {
        #expect(try TraktListProvider().suggestedTitle(for: url("https://trakt.tv/lists/5308818")) == String(localized: "Trakt List"))
    }

    @Test func `suggests nothing for a non-list URL`() throws {
        #expect(try TraktListProvider().suggestedTitle(for: url("https://trakt.tv/users/alice")) == nil)
    }

    // MARK: - entries

    @Test func `decodes items in list order and folds seasons and episodes into their show`() async throws {
        let body = """
        [{"rank": 3, "type": "movie", "movie": {"title": "A Movie", "ids": {"trakt": 1, "tmdb": 11}}},
         {"rank": 2, "type": "show", "show": {"title": "A Show", "ids": {"trakt": 2, "tmdb": 22}}},
         {"rank": 1, "type": "episode", "episode": {"season": 1, "number": 2},
          "show": {"title": "Another Show", "ids": {"trakt": 3, "tmdb": 33}}}]
        """
        StubURLProtocol.register(
            host: "api.trakt.tv", pathSuffix: "/users/decode/lists/basic/items",
            response: .init(status: 200, body: body)
        )
        let entries = try await stubbedProvider().entries(for: url("https://trakt.tv/users/decode/lists/basic"))
        #expect(entries == [
            HomeListEntry(tmdbId: 11, mediaType: .movie, title: "A Movie"),
            HomeListEntry(tmdbId: 22, mediaType: .series, title: "A Show"),
            HomeListEntry(tmdbId: 33, mediaType: .series, title: "Another Show")
        ])
    }

    @Test func `drops people and items with no TMDB id`() async throws {
        let body = """
        [{"type": "movie", "movie": {"title": "Keep", "ids": {"trakt": 1, "tmdb": 1}}},
         {"type": "movie", "movie": {"title": "No tmdb", "ids": {"trakt": 2}}},
         {"type": "person", "person": {"name": "Someone", "ids": {"trakt": 3, "tmdb": 3}}},
         {"type": "show"}]
        """
        StubURLProtocol.register(
            host: "api.trakt.tv", pathSuffix: "/users/decode/lists/partial/items",
            response: .init(status: 200, body: body)
        )
        let entries = try await stubbedProvider().entries(for: url("https://trakt.tv/users/decode/lists/partial"))
        #expect(entries.map(\.tmdbId) == [1])
    }

    /// Trakt answers 403 for a private list and for one that doesn't exist.
    @Test func `reports a private or missing list`() async throws {
        StubURLProtocol.register(
            host: "api.trakt.tv", pathSuffix: "/users/decode/lists/private/items",
            response: .init(status: 403, body: "")
        )
        await #expect(throws: HomeListError.privateList) {
            try await stubbedProvider().entries(for: url("https://trakt.tv/users/decode/lists/private"))
        }
    }

    @Test func `reports an empty list`() async throws {
        StubURLProtocol.register(
            host: "api.trakt.tv", pathSuffix: "/users/decode/lists/empty/items",
            response: .init(status: 200, body: "[]")
        )
        await #expect(throws: HomeListError.emptyList) {
            try await stubbedProvider().entries(for: url("https://trakt.tv/users/decode/lists/empty"))
        }
    }

    @Test func `reports a server error`() async throws {
        StubURLProtocol.register(
            host: "api.trakt.tv", pathSuffix: "/users/decode/lists/down/items",
            response: .init(status: 503, body: "")
        )
        await #expect(throws: HomeListError.serverError(503)) {
            try await stubbedProvider().entries(for: url("https://trakt.tv/users/decode/lists/down"))
        }
    }

    @Test func `reports a body that is not a list feed`() async throws {
        StubURLProtocol.register(
            host: "api.trakt.tv", pathSuffix: "/users/decode/lists/html/items",
            response: .init(status: 200, body: "<!doctype html>")
        )
        await #expect(throws: HomeListError.listNotFound) {
            try await stubbedProvider().entries(for: url("https://trakt.tv/users/decode/lists/html"))
        }
    }

    /// Without the app's Trakt key the provider can't read anything, so it
    /// says the source is unavailable rather than failing with an auth error.
    @Test func `reports itself unavailable without credentials`() async throws {
        let provider = TraktListProvider(client: TraktClient(
            session: StubURLProtocol.makeSession(), clientID: nil, clientSecret: nil
        ))
        await #expect(throws: HomeListError.unsupportedSource) {
            try await provider.entries(for: url("https://trakt.tv/users/decode/lists/basic"))
        }
    }

    // MARK: - Catalog

    @Test func `catalog routes a trakt URL to this provider`() {
        #expect(HomeListCatalog.provider(for: "app.trakt.tv/users/alice/lists/favs") is TraktListProvider)
    }

    @Test func `names every provider in the supported-sites text`() {
        #expect(HomeListCatalog.providerNames.contains("Trakt"))
        #expect(HomeListCatalog.providerNames.contains("MDBList"))
    }
}

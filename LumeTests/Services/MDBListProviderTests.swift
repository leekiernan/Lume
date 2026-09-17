import Foundation
@testable import Lume
import Testing

struct MDBListProviderTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    // MARK: - canHandle

    @Test func `claims mdblist hosts`() throws {
        let provider = MDBListProvider()
        #expect(try provider.canHandle(url("https://mdblist.com/lists/official/movies/popular")))
        #expect(try provider.canHandle(url("https://www.mdblist.com/lists/official/movies/popular")))
        #expect(try provider.canHandle(url("https://MDBList.com/lists/u/l")))
    }

    @Test func `ignores other hosts`() throws {
        let provider = MDBListProvider()
        #expect(try !provider.canHandle(url("https://example.com/lists/official/movies/popular")))
        #expect(try !provider.canHandle(url("https://notmdblist.com/lists/u/l")))
    }

    // MARK: - jsonURL

    /// The whole point of the feature: the user pastes the page they were
    /// looking at, never the `/json` form.
    @Test func `appends json to a list page URL`() throws {
        let result = try MDBListProvider.jsonURL(for: url("https://mdblist.com/lists/official/movies/popular"))
        #expect(result?.absoluteString == "https://mdblist.com/lists/official/movies/popular/json")
    }

    @Test func `tolerates a trailing slash`() throws {
        let result = try MDBListProvider.jsonURL(for: url("https://mdblist.com/lists/official/movies/popular/"))
        #expect(result?.absoluteString == "https://mdblist.com/lists/official/movies/popular/json")
    }

    @Test func `is idempotent when the user already pasted the json URL`() throws {
        let result = try MDBListProvider.jsonURL(for: url("https://mdblist.com/lists/official/movies/popular/json"))
        #expect(result?.absoluteString == "https://mdblist.com/lists/official/movies/popular/json")
    }

    @Test func `drops query and fragment`() throws {
        let result = try MDBListProvider.jsonURL(for: url("https://mdblist.com/lists/u/mylist?sort=rank#top"))
        #expect(result?.absoluteString == "https://mdblist.com/lists/u/mylist/json")
    }

    @Test func `lowercases the host and forces https`() throws {
        let result = try MDBListProvider.jsonURL(for: url("http://WWW.MDBList.com/lists/u/mylist"))
        #expect(result?.absoluteString == "https://www.mdblist.com/lists/u/mylist/json")
    }

    @Test func `rejects a URL that is not a list page`() throws {
        #expect(try MDBListProvider.jsonURL(for: url("https://mdblist.com/")) == nil)
        #expect(try MDBListProvider.jsonURL(for: url("https://mdblist.com/lists")) == nil)
        #expect(try MDBListProvider.jsonURL(for: url("https://mdblist.com/search?q=x")) == nil)
    }

    // MARK: - suggestedTitle

    @Test func `suggests a title from the list slug`() throws {
        let provider = MDBListProvider()
        #expect(try provider.suggestedTitle(for: url("https://mdblist.com/lists/official/movies/popular")) == "Popular")
        #expect(try provider.suggestedTitle(for: url("https://mdblist.com/lists/u/latest-tv-shows")) == "Latest Tv Shows")
        #expect(try provider.suggestedTitle(for: url("https://mdblist.com/lists/u/top_rated/json")) == "Top Rated")
    }

    @Test func `suggests nothing for a non-list URL`() throws {
        #expect(try MDBListProvider().suggestedTitle(for: url("https://mdblist.com/")) == nil)
    }

    // MARK: - Input normalization

    @Test func `assumes https for a pasted bare host`() {
        #expect(
            HomeListCatalog.normalizedInputURL("mdblist.com/lists/u/l")?.absoluteString
                == "https://mdblist.com/lists/u/l"
        )
    }

    @Test func `trims surrounding whitespace`() {
        #expect(
            HomeListCatalog.normalizedInputURL("  https://mdblist.com/lists/u/l \n")?.absoluteString
                == "https://mdblist.com/lists/u/l"
        )
    }

    @Test func `rejects empty input`() {
        #expect(HomeListCatalog.normalizedInputURL("   ") == nil)
    }

    // MARK: - entries

    @Test func `decodes movies and shows in list order`() async throws {
        let body = """
        [{"id": 1, "rank": 0, "title": "A Movie", "mediatype": "movie", "release_year": 2026},
         {"id": 2, "rank": 1, "title": "A Show", "mediatype": "show", "release_year": 2025}]
        """
        StubURLProtocol.register(
            host: "mdblist.com", path: "/lists/decode/basic/json",
            response: .init(status: 200, body: body)
        )
        let provider = MDBListProvider(session: StubURLProtocol.makeSession())
        let entries = try await provider.entries(for: url("https://mdblist.com/lists/decode/basic"))
        #expect(entries == [
            HomeListEntry(tmdbId: 1, mediaType: .movie, title: "A Movie"),
            HomeListEntry(tmdbId: 2, mediaType: .series, title: "A Show")
        ])
    }

    @Test func `drops entries with no id or an unknown media type`() async throws {
        let body = """
        [{"id": 1, "title": "Keep", "mediatype": "movie"},
         {"title": "No id", "mediatype": "movie"},
         {"id": 3, "title": "Person", "mediatype": "person"},
         {"id": 4, "title": "No type"}]
        """
        StubURLProtocol.register(
            host: "mdblist.com", path: "/lists/decode/partial/json",
            response: .init(status: 200, body: body)
        )
        let provider = MDBListProvider(session: StubURLProtocol.makeSession())
        let entries = try await provider.entries(for: url("https://mdblist.com/lists/decode/partial"))
        #expect(entries.map(\.tmdbId) == [1])
    }

    /// MDBList answers an unknown list with 404 *and* `[]`, so the status is
    /// what separates "no such list" from "list is empty".
    @Test func `reports a missing list`() async throws {
        StubURLProtocol.register(
            host: "mdblist.com", path: "/lists/decode/missing/json",
            response: .init(status: 404, body: "[]")
        )
        let provider = MDBListProvider(session: StubURLProtocol.makeSession())
        await #expect(throws: HomeListError.listNotFound) {
            try await provider.entries(for: url("https://mdblist.com/lists/decode/missing"))
        }
    }

    @Test func `reports an empty list`() async throws {
        StubURLProtocol.register(
            host: "mdblist.com", path: "/lists/decode/empty/json",
            response: .init(status: 200, body: "[]")
        )
        let provider = MDBListProvider(session: StubURLProtocol.makeSession())
        await #expect(throws: HomeListError.emptyList) {
            try await provider.entries(for: url("https://mdblist.com/lists/decode/empty"))
        }
    }

    @Test func `reports a server error`() async throws {
        StubURLProtocol.register(
            host: "mdblist.com", path: "/lists/decode/down/json",
            response: .init(status: 503, body: "")
        )
        let provider = MDBListProvider(session: StubURLProtocol.makeSession())
        await #expect(throws: HomeListError.serverError(503)) {
            try await provider.entries(for: url("https://mdblist.com/lists/decode/down"))
        }
    }

    @Test func `reports a body that is not a list feed`() async throws {
        StubURLProtocol.register(
            host: "mdblist.com", path: "/lists/decode/html/json",
            response: .init(status: 200, body: "<!doctype html>")
        )
        let provider = MDBListProvider(session: StubURLProtocol.makeSession())
        await #expect(throws: HomeListError.listNotFound) {
            try await provider.entries(for: url("https://mdblist.com/lists/decode/html"))
        }
    }

    // MARK: - Catalog routing

    @Test func `catalog rejects an unsupported host`() async {
        await #expect(throws: HomeListError.unsupportedSource) {
            try await HomeListCatalog.entries(for: "https://example.com/lists/u/l")
        }
    }

    @Test func `catalog rejects unparseable input`() async {
        await #expect(throws: HomeListError.invalidURL) {
            try await HomeListCatalog.entries(for: "   ")
        }
    }

    @Test func `every provider ships a usable example URL`() throws {
        for provider in HomeListCatalog.providers {
            let example = try #require(HomeListCatalog.normalizedInputURL(provider.exampleURL))
            #expect(provider.canHandle(example))
            #expect(!provider.displayName.isEmpty)
        }
    }
}

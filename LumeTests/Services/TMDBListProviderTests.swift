import Foundation
@testable import Lume
import Testing

/// The web→API translation is a fixed table plus the list-id case, so it is
/// worth pinning: a user pastes the page they were looking at, and every shape
/// below has to resolve without them knowing an API exists.
struct TMDBListProviderTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    // MARK: - canHandle

    @Test func `claims themoviedb hosts`() throws {
        let provider = TMDBListProvider()
        #expect(try provider.canHandle(url("https://www.themoviedb.org/movie/top-rated")))
        #expect(try provider.canHandle(url("https://themoviedb.org/list/123")))
        #expect(try provider.canHandle(url("https://TheMovieDB.org/tv")))
    }

    @Test func `ignores other hosts`() throws {
        let provider = TMDBListProvider()
        #expect(try !provider.canHandle(url("https://mdblist.com/lists/u/l")))
        #expect(try !provider.canHandle(url("https://themoviedb.com/movie/top-rated")))
    }

    // MARK: - Curated feeds

    @Test func `maps the curated movie feeds`() throws {
        let cases = [
            ("https://www.themoviedb.org/movie", "movie/popular"),
            ("https://www.themoviedb.org/movie/popular", "movie/popular"),
            ("https://www.themoviedb.org/movie/top-rated", "movie/top_rated"),
            ("https://www.themoviedb.org/movie/upcoming", "movie/upcoming"),
            ("https://www.themoviedb.org/movie/now-playing", "movie/now_playing")
        ]
        for (page, apiPath) in cases {
            let feed = try TMDBListProvider.feed(for: url(page))
            #expect(feed?.path == apiPath)
            #expect(feed?.media == .movie)
        }
    }

    @Test func `maps the curated tv feeds`() throws {
        let cases = [
            ("https://www.themoviedb.org/tv", "tv/popular"),
            ("https://www.themoviedb.org/tv/top-rated", "tv/top_rated"),
            ("https://www.themoviedb.org/tv/on-the-air", "tv/on_the_air"),
            ("https://www.themoviedb.org/tv/airing-today", "tv/airing_today")
        ]
        for (page, apiPath) in cases {
            let feed = try TMDBListProvider.feed(for: url(page))
            #expect(feed?.path == apiPath)
            #expect(feed?.media == .series)
        }
    }

    @Test func `tolerates a trailing slash and query`() throws {
        let feed = try TMDBListProvider.feed(for: url("https://www.themoviedb.org/movie/top-rated/?language=en-US"))
        #expect(feed?.path == "movie/top_rated")
    }

    // MARK: - User lists

    /// TMDB list URLs carry a slug after the id; only the digits matter, and a
    /// mixed list says what each row is, so no media kind is assumed.
    @Test func `maps a user list, slug and all`() throws {
        for page in ["https://www.themoviedb.org/list/8271667",
                     "https://www.themoviedb.org/list/8271667-best-of-the-year"]
        {
            let feed = try TMDBListProvider.feed(for: url(page))
            #expect(feed?.path == "list/8271667")
            #expect(feed?.media == nil)
        }
    }

    @Test func `rejects a list URL with no id`() throws {
        #expect(try TMDBListProvider.feed(for: url("https://www.themoviedb.org/list/")) == nil)
        #expect(try TMDBListProvider.feed(for: url("https://www.themoviedb.org/list/best-of")) == nil)
    }

    // MARK: - Non-list pages

    /// A single title, a person or a season is not a list — better to say so in
    /// the editor than to save a row that can never resolve.
    @Test func `rejects pages that are not lists`() throws {
        let rejected = [
            "https://www.themoviedb.org/",
            "https://www.themoviedb.org/movie/603-the-matrix",
            "https://www.themoviedb.org/tv/1399-game-of-thrones/season/1",
            "https://www.themoviedb.org/person/287-brad-pitt",
            "https://www.themoviedb.org/search?query=matrix"
        ]
        for page in rejected {
            #expect(try TMDBListProvider.feed(for: url(page)) == nil, "expected \(page) to be rejected")
        }
    }

    // MARK: - Titles

    @Test func `suggests a title from a curated feed`() throws {
        let provider = TMDBListProvider()
        #expect(try provider.suggestedTitle(for: url("https://www.themoviedb.org/movie/top-rated")) == "Top Rated")
        #expect(try provider.suggestedTitle(for: url("https://www.themoviedb.org/tv/on-the-air")) == "On The Air")
    }

    @Test func `suggests a generic title for a user list`() throws {
        let provider = TMDBListProvider()
        let title = try provider.suggestedTitle(for: url("https://www.themoviedb.org/list/8271667-best-of"))
        #expect(title == String(localized: "TMDB List"))
    }

    // MARK: - Catalog registration

    @Test func `the catalog routes themoviedb URLs here`() {
        let provider = HomeListCatalog.provider(for: "https://www.themoviedb.org/movie/top-rated")
        #expect(provider?.displayName == "TMDB")
    }

    @Test func `mdblist still routes to its own provider`() {
        let provider = HomeListCatalog.provider(for: "https://mdblist.com/lists/official/movies/popular")
        #expect(provider?.displayName == "MDBList")
    }
}

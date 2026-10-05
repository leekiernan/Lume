import Foundation
@testable import Lume
import Testing

struct TMDBArtworkURLTests {
    @Test func `poster construction shares the card fallback URL`() {
        let path = " /poster.jpg\n"
        #expect(TMDBClient.posterURL(path)?.absoluteString == "https://image.tmdb.org/t/p/w500/poster.jpg")
        #expect(TMDBClient.posterURL(path) == PosterArtworkSource(provider: nil, posterPath: path).primaryURL)
        #expect(TMDBClient.posterURL(path, size: "original")?.path == "/t/p/original/poster.jpg")
        #expect(TMDBClient.posterURL(nil) == nil)
    }

    @Test(arguments: ["", "//poster.jpg", "/folder/poster.jpg", "/poster.jpg?q=1", "/poster.jpg#part", "/poster.svg", "https://other.test/poster.jpg"])
    func `poster builder rejects non relative raster filenames`(path: String) {
        #expect(TMDBClient.posterURL(path) == nil)
    }

    @Test func `resizing preserves query fragment and escaped filename`() throws {
        let url = try #require(URL(string: "https://image.tmdb.org/t/p/original/a%20b.jpg?key=value#part"))
        let resized = try #require(HeroArtworkPolicy.posterURL(url, pixelWidth: 400))
        #expect(resized.absoluteString == "https://image.tmdb.org/t/p/w500/a%20b.jpg?key=value#part")
        #expect(HeroArtworkPolicy.posterURL(resized, pixelWidth: 400) == resized)
    }

    @Test(arguments: ["https://image.tmdb.org.other.test/t/p/original/a.jpg", "https://image.tmdb.org/t/p/unknown/a.jpg", "https://image.tmdb.org/t/p/original/folder/a.jpg", "https://image.tmdb.org/t/p/original/a.svg"])
    func `unknown artwork identities are left alone`(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(HeroArtworkPolicy.posterURL(url, pixelWidth: 400) == url)
        #expect(HeroArtworkPolicy.backdropURL(url, pixelWidth: 400) == url)
    }
}

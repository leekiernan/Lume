import Foundation
@testable import Lume
import Testing

struct PosterArtworkSourceTests {
    @Test func `valid provider remains primary and stored TMDB is failure fallback`() {
        let source = PosterArtworkSource(provider: "https://provider.example/poster.jpg?token=secret", posterPath: "/tmdb.jpg")
        #expect(source.primaryURL?.host == "provider.example")
        #expect(source.url(afterPrimaryFailure: false) == source.primaryURL)
        #expect(source.url(afterPrimaryFailure: true)?.absoluteString == "https://image.tmdb.org/t/p/w500/tmdb.jpg")
        #expect(source.diagnostic == nil)
    }

    @Test(arguments: ["", "   ", "/relative.jpg", "null", "ftp://provider.example/poster.jpg", "https://"])
    func `unusable provider uses stored poster immediately`(provider: String) {
        let source = PosterArtworkSource(provider: provider, posterPath: "/tmdb.jpg")
        #expect(source.providerURL == nil)
        #expect(source.primaryURL == source.tmdbURL)
        #expect(source.primaryURL != nil)
        #expect(source.diagnostic != nil)
        #expect(source.url(afterPrimaryFailure: true) == nil)
    }

    @Test func `nil provider and missing metadata remain explicitly unavailable`() {
        let source = PosterArtworkSource(provider: nil, posterPath: nil)
        #expect(source.primaryURL == nil)
        #expect(source.url(afterPrimaryFailure: true) == nil)
        #expect(source.diagnostic == "missing provider URL; no stored TMDB poster")
    }

    @Test func `provider whitespace is trimmed without losing authentication query`() {
        let source = PosterArtworkSource(provider: " \nhttps://provider.example/poster.jpg?token=secret\n", posterPath: nil)
        #expect(source.primaryURL?.absoluteString == "https://provider.example/poster.jpg?token=secret")
        #expect(source.url(afterPrimaryFailure: true) == nil)
    }

    @Test(arguments: ["", "https://elsewhere.example/poster.jpg", "//elsewhere.jpg", "/folder/poster.jpg", "/poster.jpg?token=secret", "/poster.jpg#part", "/error.html"])
    func `invalid TMDB paths are not invented into image requests`(path: String) {
        let source = PosterArtworkSource(provider: nil, posterPath: path)
        #expect(source.primaryURL == nil)
    }

    @Test func `identical provider and fallback are not requested twice`() {
        let source = PosterArtworkSource(provider: "https://image.tmdb.org/t/p/w500/tmdb.jpg", posterPath: "/tmdb.jpg")
        #expect(source.primaryURL != nil)
        #expect(source.url(afterPrimaryFailure: true) == nil)
    }

    @Test func `new stored enrichment makes a failed providers fallback eligible`() {
        let before = PosterArtworkSource(provider: "https://provider.example/broken.jpg", posterPath: nil)
        let after = PosterArtworkSource(provider: "https://provider.example/broken.jpg", posterPath: "/fresh.jpg")
        #expect(before.url(afterPrimaryFailure: true) == nil)
        #expect(after.url(afterPrimaryFailure: true)?.path == "/t/p/w500/fresh.jpg")
    }
}

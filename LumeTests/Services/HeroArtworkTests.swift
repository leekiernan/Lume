import Foundation
@testable import Lume
import Testing

/// A hero fills a wide letterbox. Portrait cover art blown up to fit it reads
/// as a stretched crop, so a title without a backdrop is held back rather than
/// shown — these pin that rule.
@MainActor
struct HeroArtworkTests {
    private func movie(backdropPath: String?) -> Movie {
        let movie = Movie(id: "m-1", streamId: 1, name: "A Title")
        movie.backdropPath = backdropPath
        // Provider cover art: portrait, and the fallback that used to be
        // stretched into the hero.
        movie.streamIcon = "https://example.com/poster.jpg"
        return movie
    }

    @Test func `a title with a backdrop counts as wide artwork`() throws {
        let hero = try #require(HeroItem(item: .movie(movie(backdropPath: "/wide.jpg"))))
        #expect(hero.hasWideArtwork)
    }

    /// The bug: no backdrop meant `imageURL` fell back to the portrait poster,
    /// which the hero then stretched.
    @Test func `a title with no backdrop does not`() throws {
        let hero = try #require(HeroItem(item: .movie(movie(backdropPath: nil))))
        #expect(!hero.hasWideArtwork)
        // It still resolves to *something* — the poster — which is exactly why
        // the caller has to filter rather than rely on a nil image URL.
        #expect(hero.imageURL != nil)
    }

    @Test func `an empty backdrop path is not wide artwork`() throws {
        let hero = try #require(HeroItem(item: .movie(movie(backdropPath: ""))))
        #expect(!hero.hasWideArtwork)
    }

    /// Live channels carry logos, not backdrops, and have no hero treatment.
    @Test func `live channels make no hero`() {
        let stream = LiveStream(id: "l-1", streamId: 1, name: "A Channel")
        #expect(HeroItem(item: .live(stream)) == nil)
    }
}

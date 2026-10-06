import Foundation
@testable import Lume
import Testing

@MainActor
struct HeroFactsTests {
    @Test func `genres keep the first two names, trimmed`() {
        #expect(DetailFormat.genres("Animation, Fantasy ,Adventure") == "Animation, Fantasy")
        #expect(DetailFormat.genres("Drama") == "Drama")
    }

    @Test func `genres are nil when there are none`() {
        #expect(DetailFormat.genres(nil) == nil)
        #expect(DetailFormat.genres("") == nil)
        #expect(DetailFormat.genres(" , ") == nil)
    }

    @Test func `a movie hero lists year, genres and running time`() {
        let movie = Movie(id: "movie-1", streamId: 1, name: "Sintel")
        movie.releaseDate = "2010-09-27"
        movie.genre = "Animation, Fantasy, Short"
        movie.durationSecs = 900
        let hero = HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: "")
        #expect(hero.facts == "2010 · Animation, Fantasy · 15m")
    }

    @Test func `a series hero lists year and genres`() {
        let series = Series(id: "series-1", seriesId: 1, name: "Show")
        series.releaseDate = "2019"
        series.genre = "Drama"
        let hero = HeroItem.series(series, backdropURL: nil, logoURL: nil, overview: "")
        #expect(hero.facts == "2019 · Drama")
    }

    @Test func `a hero with no known facts has none`() {
        let movie = Movie(id: "movie-2", streamId: 2, name: "Unknown")
        let hero = HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: "")
        #expect(hero.facts == nil)
    }
}

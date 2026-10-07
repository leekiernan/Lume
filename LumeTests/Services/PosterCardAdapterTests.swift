import Foundation
@testable import Lume
import Testing

@MainActor
struct PosterCardAdapterTests {
    @Test func `movie rail and grid adapters retain provider spelling and recovery scope`() {
        let movie = Movie(id: "playlist-movie", streamId: 1, name: "Movie")
        movie.streamIcon = "https://provider.test/poster.jpg?signature=a%2Bb"
        movie.posterPath = "/fallback.jpg"
        movie.categoryId = "category"
        let rail = MovieCardView(movie: movie).posterCard
        let grid = MovieCardView(movie: movie, fillsWidth: true).posterCard
        #expect(rail.title == movie.name)
        #expect(rail.provider == movie.streamIcon)
        #expect(rail.posterPath == movie.posterPath)
        #expect(rail.request == PosterArtworkRequest(kind: .movie, id: movie.id, categoryID: movie.categoryId))
        #expect(!rail.fillsWidth)
        #expect(grid.fillsWidth)
        #expect(grid.request == rail.request)
        #expect(grid.progress == nil)
        #expect(grid.badge == nil)
    }

    @Test func `series adapters retain series identity`() {
        let series = Series(id: "playlist-series", seriesId: 1, name: "Series")
        series.cover = "https://provider.test/series.jpg"
        series.posterPath = "/series.jpg"
        series.categoryId = "series-category"
        let card = SeriesCardView(series: series, fillsWidth: true).posterCard
        #expect(card.provider == series.cover)
        #expect(card.posterPath == series.posterPath)
        #expect(card.request == PosterArtworkRequest(kind: .series, id: series.id, categoryID: series.categoryId))
        #expect(card.fillsWidth)
    }

    @Test func `detail adapter keeps its badge and fixed rail width`() {
        let series = Series(id: "other-series", seriesId: 1, name: "Other Series")
        series.posterPath = "/stored.jpg"
        let card = DetailPosterCard(item: .series(series), badge: "Other playlist").posterCard
        #expect(card.title == series.name)
        #expect(card.posterPath == series.posterPath)
        #expect(card.request?.kind == .series)
        #expect(card.badge == "Other playlist")
        #expect(!card.fillsWidth)
        #expect(card.progress == nil)
    }

    @Test func `render adapters reread scalar model updates without storing a stale snapshot`() {
        let movie = Movie(id: "movie", streamId: 1, name: "Before")
        let view = MovieCardView(movie: movie)
        #expect(view.posterCard.title == "Before")
        movie.name = "After"
        movie.posterPath = "/new.jpg"
        movie.categoryId = "new-category"
        #expect(view.posterCard.title == "After")
        #expect(view.posterCard.posterPath == "/new.jpg")
        #expect(view.posterCard.request?.categoryID == "new-category")
    }
}

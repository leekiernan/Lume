import Foundation
@testable import Lume
import Testing

@MainActor
struct DetailPosterArtworkTests {
    @Test func `live logos never request TMDB poster recovery`() {
        let stream = LiveStream(id: "channel", streamId: 1, name: "Channel")
        stream.streamIcon = "https://provider.test/logo.png"
        let item = HomeMediaItem.live(stream)
        #expect(item.posterPath == nil)
        #expect(item.posterRecoveryRequest == nil)
        #expect(item.imageURL?.absoluteString == stream.streamIcon)
    }

    @Test func `movie detail cards retain fallback recovery scope and badge`() {
        let movie = Movie(id: "playlist-movie-1", streamId: 1, name: "Movie")
        movie.streamIcon = "https://provider.test/broken.jpg"
        movie.posterPath = "/stored.jpg"
        movie.categoryId = "restricted-category"
        let card = DetailPosterCard(item: .movie(movie), badge: "Other playlist")
        #expect(card.badge == "Other playlist")
        #expect(card.request == PosterArtworkRequest(kind: .movie, id: movie.id, categoryID: movie.categoryId))
        let source = PosterArtworkSource(provider: card.imageURL?.absoluteString, posterPath: card.posterPath)
        #expect(source.primaryURL == card.imageURL)
        #expect(source.url(afterPrimaryFailure: true)?.path == "/t/p/w500/stored.jpg")
    }

    @Test func `series detail cards without provider artwork use their stored poster`() {
        let series = Series(id: "playlist-series-1", seriesId: 1, name: "Series")
        series.posterPath = "/series.jpg"
        let card = DetailPosterCard(item: .series(series))
        #expect(card.request?.kind == .series)
        #expect(card.request?.id == series.id)
        #expect(PosterArtworkSource(provider: card.imageURL?.absoluteString, posterPath: card.posterPath).primaryURL?.path == "/t/p/w500/series.jpg")
    }
}

import Foundation
@testable import Lume
import Testing

/// Providers list one entry per quality tier or language, so a catalog holds
/// several rows for one film. These pin how the rails collapse them.
@MainActor
struct DuplicateTitlesTests {
    private func movie(_ id: String, tmdbId: Int?, name: String = "A Film") -> Movie {
        let movie = Movie(id: id, streamId: 1, name: name)
        movie.tmdbId = tmdbId
        return movie
    }

    private func series(_ id: String, tmdbId: Int?) -> Series {
        let series = Series(id: id, seriesId: 1, name: "A Show")
        series.tmdbId = tmdbId
        return series
    }

    // MARK: - Single-medium rails

    @Test func `copies of one title collapse to the first`() {
        let items = [
            movie("m-4k", tmdbId: 238, name: "The Godfather (4K)"),
            movie("m-hd", tmdbId: 238, name: "The Godfather HD"),
            movie("m-other", tmdbId: 240)
        ]
        let result = items.deduplicatedByTitle()
        #expect(result.map(\.id) == ["m-4k", "m-other"])
    }

    /// Order is the caller's — Recently Watched sorts before collapsing, so the
    /// copy kept is the one watched most recently.
    @Test func `the first in the given order wins`() {
        let items = [movie("m-hd", tmdbId: 238), movie("m-4k", tmdbId: 238)]
        #expect(items.deduplicatedByTitle().map(\.id) == ["m-hd"])
    }

    /// Without a TMDB id there is nothing to group by, so the row stays — the
    /// alternative is silently hiding content that simply hasn't been matched.
    @Test func `unmatched titles are always kept`() {
        let items = [movie("m-1", tmdbId: nil), movie("m-2", tmdbId: nil)]
        #expect(items.deduplicatedByTitle().count == 2)
    }

    @Test func `a catalog with no duplicates is untouched`() {
        let items = [movie("m-1", tmdbId: 1), movie("m-2", tmdbId: 2), movie("m-3", tmdbId: 3)]
        #expect(items.deduplicatedByTitle().map(\.id) == ["m-1", "m-2", "m-3"])
    }

    // MARK: - Mixed rails

    /// TMDB numbers movies and series separately, so movie 238 and series 238
    /// are unrelated titles and must not collapse into one another.
    @Test func `a movie and a series sharing a number stay separate`() {
        let items: [HomeMediaItem] = [
            .movie(movie("m-1", tmdbId: 238)),
            .series(series("s-1", tmdbId: 238))
        ]
        #expect(items.deduplicatedByTitle().count == 2)
    }

    @Test func `mixed rails collapse within each medium`() {
        let items: [HomeMediaItem] = [
            .movie(movie("m-4k", tmdbId: 238)),
            .series(series("s-1", tmdbId: 1399)),
            .movie(movie("m-hd", tmdbId: 238)),
            .series(series("s-2", tmdbId: 1399))
        ]
        let result = items.deduplicatedByTitle()
        #expect(result.map(\.id) == ["movie-m-4k", "series-s-1"])
    }

    /// Two channels showing the same film are genuinely two channels, and have
    /// no TMDB identity to group on regardless.
    @Test func `live channels are never collapsed`() {
        let items: [HomeMediaItem] = [
            .live(LiveStream(id: "l-1", streamId: 1, name: "Channel One")),
            .live(LiveStream(id: "l-2", streamId: 2, name: "Channel Two"))
        ]
        #expect(items.deduplicatedByTitle().count == 2)
    }
}

import Foundation
@testable import Lume
import Testing

/// Catalogue-owned values a refresh must keep current: the TMDB ID a
/// catalogue supplied, and an episode's playback inputs.
struct CatalogueRefreshTests {
    private func enriched(_ movie: Movie) {
        movie.tmdbEnrichedAt = Date()
        movie.tmdbArtworkEnrichedAt = Date()
        movie.ratingsEnrichedAt = Date()
    }

    @Test func `a withdrawn catalogue ID is cleared and its enrichment forgotten`() {
        let movie = Movie(id: "p-movie-1", streamId: 1, name: "Film")
        movie.applyCatalogueTMDB("603", previous: nil)
        #expect(movie.tmdbId == 603)
        enriched(movie)

        movie.applyCatalogueTMDB("", previous: "603")
        #expect(movie.tmdbId == nil)
        #expect(movie.tmdbEnrichedAt == nil && movie.tmdbArtworkEnrichedAt == nil && movie.ratingsEnrichedAt == nil)
    }

    @Test func `a device-resolved ID survives a catalogue that never sent one`() {
        let movie = Movie(id: "p-movie-2", streamId: 2, name: "Film")
        movie.tmdbId = 27205 // from the device's own search
        enriched(movie)
        for raw in [nil, "", "0"] {
            movie.applyCatalogueTMDB(raw, previous: raw)
        }
        #expect(movie.tmdbId == 27205 && movie.tmdbEnrichedAt != nil)
        // A different stored ID than the one the catalogue withdrew is not touched.
        movie.applyCatalogueTMDB("", previous: "603")
        #expect(movie.tmdbId == 27205)
    }

    @Test func `a corrected catalogue ID re-enriches the new title`() {
        let movie = Movie(id: "p-movie-3", streamId: 3, name: "Film")
        movie.applyCatalogueTMDB("603", previous: nil)
        enriched(movie)
        movie.applyCatalogueTMDB("604", previous: "603")
        #expect(movie.tmdbId == 604 && movie.tmdbEnrichedAt == nil)
        // Unchanged values are no-ops and keep freshness.
        enriched(movie)
        movie.applyCatalogueTMDB("604", previous: "604")
        #expect(movie.tmdbEnrichedAt != nil)
        #expect(Movie.catalogueTMDB("0") == nil && Movie.catalogueTMDB(" 42 ") == 42 && Movie.catalogueTMDB("abc") == nil)
    }

    @Test func `series catalogue IDs replace and re-enrich; detail only fills; neither withdraws`() {
        let series = Series(id: "p-series-1", seriesId: 1, name: "Show")
        series.applyProviderMetadata(SeriesMetadata(tmdb: "1429"), fillMissing: false)
        #expect(series.tmdb == "1429" && series.tmdbId == 1429)
        series.applyProviderMetadata(SeriesMetadata(tmdb: "9999"), fillMissing: true)
        #expect(series.tmdbId == 1429) // get_series_info never overrides the catalogue
        series.tmdbEnrichedAt = Date()
        series.applyProviderMetadata(SeriesMetadata(tmdb: "1430"), fillMissing: false)
        #expect(series.tmdbId == 1430 && series.tmdb == "1430" && series.tmdbEnrichedAt == nil)
        // A sparse row may be hiding a detail-supplied ID, so it is kept.
        series.applyProviderMetadata(SeriesMetadata(tmdb: "0"), fillMissing: false)
        #expect(series.tmdbId == 1430 && series.tmdb == "1430")
    }

    @Test func `episode refresh updates playback inputs but ignores empty values`() {
        let episode = Episode(id: "p-ep-1", episodeId: "1", title: "Pilot", containerExtension: "mkv", seasonNum: 1, episodeNum: 1,
                              directSource: "cmd-old")
        episode.applyProviderMetadata(parsed(title: "Pilot (Remastered)", containerExtension: "mp4", seasonNum: 1, episodeNum: 2, directSource: "cmd-new"))
        #expect(episode.containerExtension == "mp4" && episode.title == "Pilot (Remastered)")
        #expect(episode.directSource == "cmd-new" && episode.episodeNum == 2)
        episode.applyProviderMetadata(parsed(title: " ", containerExtension: "", seasonNum: 0, episodeNum: 0, directSource: nil))
        #expect(episode.containerExtension == "mp4" && episode.title == "Pilot (Remastered)")
        #expect(episode.directSource == "cmd-new" && episode.seasonNum == 1 && episode.episodeNum == 2)
    }

    private func parsed(title: String, containerExtension: String, seasonNum: Int, episodeNum: Int, directSource: String?) -> ParsedEpisode {
        ParsedEpisode(id: "p-ep-1", episodeId: "1", title: title, containerExtension: containerExtension, seasonNum: seasonNum,
                      episodeNum: episodeNum, added: nil, directSource: directSource, durationSecs: nil, movieImage: nil,
                      rating: nil, airDate: nil, plot: nil)
    }
}

private struct SeriesMetadata: XtreamSeriesMetadata {
    var cover: String?
    var plot: String?
    var cast: String?
    var director: String?
    var genre: String?
    var releaseDate: String?
    var rating: String?
    var tmdb: String?

    init(tmdb: String?) {
        self.tmdb = tmdb
    }
}

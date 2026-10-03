import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct DetailLoadMachineTests {
    private func episode(_ number: Int, season: Int, series: Series) -> Episode {
        Episode(id: "\(series.id)-\(season)-\(number)", episodeId: "\(number)", title: "Episode",
                containerExtension: "mp4", seasonNum: season, episodeNum: number, series: series)
    }

    @Test func `series projection orders episodes and preserves a valid user selected season`() {
        let series = Series(id: "series", seriesId: 1, name: "Series")
        series.episodes = [episode(3, season: 2, series: series), episode(1, season: 1, series: series),
                           episode(1, season: 2, series: series)]
        let machine = SeriesDetailLoadMachine(series: series)
        machine.recomputeSeasons(series)
        machine.selectedSeason = 2
        series.episodes.append(episode(2, season: 2, series: series))
        machine.recomputeSeasons(series)
        #expect(machine.availableSeasons == [1, 2])
        #expect(machine.episodesBySeason[2]?.map(\.episodeNum) == [1, 2, 3])
        #expect(machine.selectedSeason == 2)
    }

    @Test func `series projection repairs a removed selected season and resets for another title`() {
        let series = Series(id: "first", seriesId: 1, name: "First")
        series.episodes = [episode(1, season: 2, series: series)]
        let machine = SeriesDetailLoadMachine(series: series)
        machine.recomputeSeasons(series)
        #expect(machine.selectedSeason == 2)
        let replacement = Series(id: "second", seriesId: 2, name: "Second")
        machine.recomputeSeasons(replacement)
        #expect(machine.contentID == replacement.id)
        #expect(machine.availableSeasons.isEmpty)
        #expect(machine.episodesBySeason.isEmpty)
        #expect(machine.selectedSeason == 1)
    }

    @Test func `initial series load picks furthest progress without requiring a playlist`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let series = Series(id: "series", seriesId: 1, name: "Series")
        let first = episode(1, season: 1, series: series)
        let later = episode(2, season: 3, series: series)
        later.watchProgress = 60
        series.episodes = [first, later]
        context.insert(series)
        let machine = SeriesDetailLoadMachine(series: series)
        await machine.load(series, playlist: nil, in: context)
        #expect(machine.selectedSeason == 3)
        #expect(!machine.isLoadingTMDB)
        #expect(!machine.isLoadingEpisodes)
        machine.selectedSeason = 1
        await machine.refreshEpisodesIfStale(series, playlist: nil, in: context)
        #expect(machine.selectedSeason == 1)
    }

    @Test func `episode retry without a playlist settles without stamping freshness`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let series = Series(id: "series", seriesId: 1, name: "Series")
        context.insert(series)
        let machine = SeriesDetailLoadMachine(series: series)
        await machine.loadEpisodes(series, playlist: nil, in: context)
        #expect(!machine.isLoadingEpisodes)
        #expect(series.episodes.isEmpty)
        #expect(series.episodesFetchedAt == nil)
    }

    @Test func `movie load without metadata settles and collection removal clears the lane`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        context.insert(movie)
        let machine = MovieDetailLoadMachine(movie: movie)
        await machine.load(movie, in: context)
        await machine.loadCollection(movie, in: context)
        #expect(!machine.isLoadingTMDB)
        #expect(machine.collectionID == nil)
        #expect(machine.collectionMovies.isEmpty)
    }
}

import Observation
import SwiftData

/// Shared data lifecycle, deliberately independent of episode row layout and
/// tvOS focus. Cached episode refresh is a separate lane from initial details.
@Observable
final class SeriesDetailLoadMachine {
    private(set) var contentID: String
    private var detail: DetailLoadState
    private var episodeLoad = DetailLoadState()
    private(set) var similar: [HomeMediaItem] = []
    private(set) var otherSources: [OtherSources.Source] = []
    private(set) var availableSeasons: [Int] = []
    private(set) var episodesBySeason: [Int: [Episode]] = [:]
    var selectedSeason = 1

    var isLoadingTMDB: Bool {
        detail.isBlocking
    }

    var isLoadingEpisodes: Bool {
        episodeLoad.isLoading
    }

    init(series: Series) {
        contentID = series.id
        detail = DetailLoadState(isBlocking: detailNeedsTMDBFetch(tmdbId: series.tmdbId, enrichedAt: series.tmdbEnrichedAt))
    }

    func load(_ series: Series, playlist: Playlist?, in context: ModelContext) async {
        prepare(series)
        let request = detail.begin()
        if series.episodes.isEmpty {
            await loadEpisodes(series, playlist: playlist, in: context)
        }
        guard !Task.isCancelled, detail.owns(request) else { return }
        recomputeSeasons(series)
        selectedSeason = defaultSeason(series)
        await enrichSeriesDetailsIfNeeded(series, context: context)
        guard !Task.isCancelled, detail.owns(request) else { return }
        await enrichSeriesRatingsIfNeeded(series, context: context)
        guard !Task.isCancelled, detail.owns(request) else { return }
        resolveSimilar(series, in: context)
        otherSources = OtherSources.resolve(for: series, in: context)
        detail.finish(request)
    }

    func refreshEpisodesIfStale(_ series: Series, playlist: Playlist?, in context: ModelContext) async {
        prepare(series)
        guard !series.episodes.isEmpty,
              let playlist, playlist.supportsPerSeriesEpisodeFetch,
              series.episodesAreStale(lastSyncedAt: playlist.lastSyncDate)
        else { return }
        // Do not reset selectedSeason while the viewer is browsing.
        await loadEpisodes(series, playlist: playlist, in: context)
    }

    func loadEpisodes(_ series: Series, playlist: Playlist?, in context: ModelContext) async {
        prepare(series)
        guard let playlist, !episodeLoad.isLoading else { return }
        let request = episodeLoad.begin()
        defer { episodeLoad.finish(request) }
        let manager = ContentSyncManager(modelContainer: context.container)
        guard let parsed = try? await manager.fetchEpisodes(
            seriesId: series.seriesId, seriesElementId: series.id, playlist: playlist
        ), !Task.isCancelled, episodeLoad.owns(request) else { return }
        // A failed or cancelled fetch must not stamp the cache as fresh.
        series.insertEpisodes(parsed, into: context)
        recomputeSeasons(series)
    }

    func recomputeSeasons(_ series: Series) {
        prepare(series)
        availableSeasons = Set(series.episodes.map(\.seasonNum)).sorted()
        episodesBySeason = Dictionary(grouping: series.episodes, by: \.seasonNum)
            .mapValues { $0.sorted { $0.episodeNum < $1.episodeNum } }
        if !availableSeasons.isEmpty, !availableSeasons.contains(selectedSeason) {
            selectedSeason = defaultSeason(series)
        }
    }

    private func defaultSeason(_ series: Series) -> Int {
        let markers = SeriesEpisodeProgress.markers(in: series.episodes)
        let target = markers.furthestInProgress ?? markers.furthestAnyProgress
        if let target, availableSeasons.contains(target.seasonNum) { return target.seasonNum }
        return availableSeasons.first ?? 1
    }

    func resolveSimilar(_ series: Series, in context: ModelContext) {
        prepare(series)
        similar = RelatedTitlesResolver.similar(to: series, in: context)
    }

    func invalidate() {
        detail.invalidate()
        episodeLoad.invalidate()
    }

    private func prepare(_ series: Series) {
        guard contentID != series.id else { return }
        invalidate()
        contentID = series.id
        similar = []
        otherSources = []
        availableSeasons = []
        episodesBySeason = [:]
        selectedSeason = 1
        detail = DetailLoadState(isBlocking: detailNeedsTMDBFetch(tmdbId: series.tmdbId, enrichedAt: series.tmdbEnrichedAt))
    }
}

//
//  HomeView+DerivedContent.swift
//  Lume
//
//  Home's Recently Watched / Favorites rows and the empty-state check they
//  feed, split from HomeView.swift purely to keep that file under the
//  line-length cap.
//

import Foundation
import SwiftData

extension HomeView {
    // MARK: - Derived content

    /// The channels Home may show: none when this profile has Live TV switched
    /// off. That area leaves the navigation and stops syncing, so its channels
    /// shouldn't keep turning up inside Home's mixed rows either — and unlike
    /// movies and series, they have no row of their own to switch off, because
    /// they only ever appear alongside other media.
    private func visibleChannels(_ streams: [LiveStream]) -> [LiveStream] {
        guard AppAreaSettings.isEnabled(.liveTV, disabledRaw: disabledAreasRaw) else { return [] }
        return streams.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction)
    }

    var recentlyWatched: [HomeMediaItem] {
        let items = watchedMovies.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.movie)
            + watchedSeries.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction).map(HomeMediaItem.series)
            + visibleChannels(watchedStreams).map(HomeMediaItem.live)
        return items
            .sorted { ($0.lastWatchedDate ?? .distantPast) > ($1.lastWatchedDate ?? .distantPast) }
            // After sorting, so the copy kept is the one watched most recently.
            .deduplicatedByTitle()
            .prefix(10)
            .map(\.self)
    }

    var favorites: [HomeMediaItem] {
        let movies = favoriteMovies.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction)
        let series = favoriteSeries.filter { belongsToActivePlaylist($0.id) }.excludingRestricted(restriction)
        let streams = visibleChannels(favoriteStreams)

        // Interleave the three types by the cross-type `favoriteOrder` set in
        // Content Management → Favorites, so a movie placed above a channel shows
        // above it here too. Items never reordered (nil) fall back to a stable
        // type/name grouping (channels, movies, then series) — the same fallback
        // the favorites manager uses.
        let entries: [(order: Int?, rank: Int, name: String, item: HomeMediaItem)] =
            streams.map { ($0.favoriteOrder, 0, $0.name, HomeMediaItem.live($0)) }
                + movies.map { ($0.favoriteOrder, 1, $0.name, HomeMediaItem.movie($0)) }
                + series.map { ($0.favoriteOrder, 2, $0.name, HomeMediaItem.series($0)) }

        return entries
            .sorted { ($0.order ?? Int.max, $0.rank, $0.name) < ($1.order ?? Int.max, $1.rank, $1.name) }
            .map(\.item)
            .deduplicatedByTitle()
    }

    /// Truly empty home — only show the empty state once trending has settled
    /// so async-loaded content doesn't make the empty view flash on launch.
    var isEmpty: Bool {
        recentlyWatched.isEmpty
            && favorites.isEmpty
            && feed.items(for: .builtin(.trendingMovies)).isEmpty
            && feed.items(for: .builtin(.trendingSeries)).isEmpty
            && feed.items(for: .builtin(.traktWatchlist)).isEmpty
            && visibleCustomSections.allSatisfy { feed.items(for: .custom($0.id)).isEmpty }
            && !sportsRailHasContent
            && feed.isSettled
    }

    // MARK: - Recently watched

    /// Clears an item's watch timestamp so it drops out of the Recently Watched
    /// row. The @Query-backed rows update automatically once the change is saved.
    func removeFromRecentlyWatched(_ item: HomeMediaItem) {
        switch item {
        case let .movie(movie): movie.lastWatchedDate = nil
        case let .series(series): series.lastWatchedDate = nil
        case let .live(stream):
            // Shared with Live TV so the in-player rail and recall agree.
            LiveChannelHistory.removeFromRecents(stream, in: modelContext)
            return
        }
        try? modelContext.save()
    }

    // MARK: - Series resume

    /// Resolves the resume bar for every partially-watched series in one indexed
    /// fetch, off the main thread. The rails then read a plain dictionary rather
    /// than each card faulting its series' whole `episodes` relationship from
    /// `body` — the same hoist the Live TV list does for now/next EPG.
    func loadSeriesResume() async {
        let container = modelContext.container
        seriesResume = await Task.detached(priority: .userInitiated) {
            SeriesResumeLoader.load(container: container)
        }.value
    }
}

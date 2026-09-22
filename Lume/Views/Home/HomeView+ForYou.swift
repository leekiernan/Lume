//
//  HomeView+ForYou.swift
//  Lume
//
//  The opt-in "For You" recommendations row on Home. Split from `HomeView` to
//  keep that file within size limits. Unlike the other remote-backed rows this
//  one is computed on-device by `RecommendationEngine`, so it lives here rather
//  than in the shared `SectionFeed`.
//

import SwiftData
import SwiftUI

extension HomeView {
    /// Refresh the row when the active playlist, the favorites/history queries or
    /// the hidden categories change. This only re-resolves the list (cheap, and
    /// re-validates each entry against live state) — the engine still throttles the actual re-ranking to
    /// its recalculation interval.
    var recommendationsKey: String {
        let counts = "\(watchedMovies.count)-\(watchedSeries.count)-\(favoriteMovies.count)-\(favoriteSeries.count)"
        let visibility = restriction.visibilityToken
        return "rec-\(recommendationsEnabled)-\(premium.isPremium)-\(isSyncBusy)-\(recommendationsRecalcToken)-\(counts)-\(selectedPlaylistID)-\(visibility)"
    }

    /// True while a playlist sync, iCloud sync or EPG import is running. The For
    /// You recompute reads and ranks the whole catalog, so on older devices it's
    /// deferred until those finish — and during a CloudKit import, touching the
    /// catalog mid-handshake is best avoided entirely. Folded into
    /// `recommendationsKey` so the load retries the moment syncing settles.
    var isSyncBusy: Bool {
        playlists.contains { $0.syncStatus == .syncing }
            || indexing.isCloudSyncActive
            || epgSync.isSyncing
    }

    /// Resolves the engine's (throttled, possibly cached) list to local models,
    /// dropping any that are no longer recommendable — watched, favorited or
    /// voted on since the list was computed. That live re-validation is what lets
    /// a vote remove a card without forcing a full re-rank.
    func loadRecommendations() async {
        guard recommendationsEnabled, premium.isPremium else {
            recommendations = []
            return
        }
        // Don't calculate while syncing — leave whatever is already shown (or the
        // loading placeholder) in place; the task re-fires once `isSyncBusy` clears.
        guard !isSyncBusy else { return }

        let interval = Perf.begin(.homeRecommendations)
        defer { Perf.end(interval) }

        let engine = RecommendationEngine(modelContainer: modelContext.container)
        let scored = await engine.recommendations(excluding: restriction.excludedCategoryIDs)
        var items: [HomeMediaItem] = []
        for recommendation in scored {
            switch recommendation.kind {
            case .movie:
                if let movie = fetchMovie(id: recommendation.id), isRecommendable(movie) { items.append(.movie(movie)) }
            case .series:
                if let series = fetchSeries(id: recommendation.id), isRecommendable(series) { items.append(.series(series)) }
            }
            if items.count >= 10 { break }
        }
        recommendations = items
        recommendationsLoaded = true
    }

    func isRecommendable(_ movie: Movie) -> Bool {
        !movie.isWatched && !movie.isFavorite && movie.lastWatchedDate == nil && movie.recommendationVote == nil
    }

    func isRecommendable(_ series: Series) -> Bool {
        !series.isFavorite && series.lastWatchedDate == nil && series.recommendationVote == nil
    }

    func fetchMovie(id: String) -> Movie? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let movie = try? modelContext.fetch(descriptor).first,
              belongsToActivePlaylist(movie.id), !restriction.hides(categoryID: movie.categoryId)
        else { return nil }
        return movie
    }

    func fetchSeries(id: String) -> Series? {
        var descriptor = FetchDescriptor<Series>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let series = try? modelContext.fetch(descriptor).first,
              belongsToActivePlaylist(series.id), !restriction.hides(categoryID: series.categoryId)
        else { return nil }
        return series
    }

    /// Records an up/down vote for a recommendation. Either vote drops the title
    /// from the row immediately (it's been acted on) and steers the next recompute
    /// — an upvote pulls the taste profile toward it, a downvote away. The vote is
    /// persisted now; the engine folds it in on its next (throttled) recompute.
    func vote(_ item: HomeMediaItem, _ vote: RecommendationVote) {
        switch item {
        case let .movie(movie): movie.recommendationVote = vote
        case let .series(series): series.recommendationVote = vote
        case .live: return
        }
        // Persisted on the catalog model like favorites/watch state; the iCloud
        // reconciler mirrors it to UserContentState so the vote syncs.
        try? modelContext.save()

        recommendations.removeAll { $0.id == item.id }
    }
}

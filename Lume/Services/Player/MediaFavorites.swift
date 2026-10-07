//
//  MediaFavorites.swift
//  Lume
//
//  The one VOD favorite semantic, shared by the card menus, the detail screens,
//  the favorites manager and `PlayerFavorites`: a movie or series also stamps
//  `addedToWatchlistDate`, unlike a live stream which toggles the flag alone
//  (`LiveChannelFavorites`). An episode routes to its parent — episodes have no
//  `isFavorite` of their own.
//

import Foundation
import SwiftData

/// One heart combines local favourites, Trakt watchlist and Simkl Plan to Watch.
/// On adds to all connected trackers; off removes only existing memberships.
/// Simkl off moves to Dropped, preserving watched history and ratings.
///
/// A new favorite deliberately leaves `favoriteOrder` alone. Both surfaces that
/// render favorites sort on `favoriteOrder ?? Int.max` (`HomeView.favoriteItems`
/// and `FavoriteManagementView`), so an unstamped favorite already sorts *after*
/// every hand-ordered one — stamping a next-highest slot here would instead put
/// it ahead of the whole unordered block for anyone who never opened the
/// favorites manager.
enum MediaFavorites {
    private static var pendingToggles: Set<String> = []

    /// UI taps resolve tracker membership first, including when no watchlist rail
    /// is enabled. Coalesce repeated taps and don't carry a choice into a new scope.
    static func requestToggle(_ model: some WatchlistFavoritable, in context: ModelContext) {
        guard pendingToggles.insert(model.id).inserted else { return }
        let profile = ActiveProfileStore.current
        let traktAccount = TraktService.shared.mutations.account
        let simklAccount = SimklService.shared.mutations.account
        Task {
            defer { pendingToggles.remove(model.id) }
            async let trakt: Void = TraktService.shared.refreshWatchlistIfNeeded()
            async let simkl: Void = SimklService.shared.refreshWatchlistIfNeeded()
            _ = await (trakt, simkl)
            guard ActiveProfileStore.current == profile,
                  TraktService.shared.mutations.account == traktAccount,
                  SimklService.shared.mutations.account == simklAccount else { return }
            toggle(model, in: context)
        }
    }

    static func state(_ model: any FavoriteOrderable) -> MediaFavoriteState {
        let target = target(model)
        let trakt = TraktService.shared
        let simkl = SimklService.shared
        return MediaFavoriteState(
            local: model.isFavorite,
            trakt: trakt.isConnected ? target.map { trakt.mutations.isWatchlisted($0) } : nil,
            simkl: simkl.isConnected ? target.map { simkl.mutations.isWatchlisted($0) } : nil
        )
    }

    static func isFavorite(_ model: any FavoriteOrderable) -> Bool {
        state(model).isFavorite
    }

    private static func target(_ model: any FavoriteOrderable) -> TrackerMutation.Target? {
        if let movie = model as? Movie, let id = movie.tmdbId { return .movie(tmdbID: id) }
        if let series = model as? Series, let id = series.tmdbId { return .show(tmdbID: id) }
        return nil
    }

    @discardableResult
    static func toggle(_ model: some WatchlistFavoritable, in context: ModelContext) -> Bool {
        let state = state(model)
        let favorited = state.toggled
        apply(state.toggleChange, to: model, in: context)
        return favorited
    }

    /// A native menu supplies an explicit choice, not a second combined toggle.
    /// Tracker-only changes do not save or clear local favourites/watch history.
    static func set(_ isPresent: Bool, in destination: MediaFavoriteState.Destination,
                    for model: some WatchlistFavoritable, context: ModelContext)
    {
        guard !pendingToggles.contains(model.id),
              let change = state(model).change(setting: isPresent, in: destination) else { return }
        apply(change, to: model, in: context)
    }

    private static func apply(_ change: MediaFavoriteState.Change, to model: some WatchlistFavoritable, in context: ModelContext) {
        if let local = change.local {
            if local {
                if !model.isFavorite { model.addedToWatchlistDate = Date() }
                model.isFavorite = true
            } else {
                clearFavoriteFields(model)
            }
            try? context.save()
        }
        syncWatchlists(model, trakt: change.trakt, simkl: change.simkl)
    }

    @discardableResult
    static func toggle(_ episode: Episode, in context: ModelContext) -> Bool {
        guard let series = episode.series else { return false }
        return toggle(series, in: context)
    }

    /// The single unfavorite semantic, shared with `FavoriteManagementView`.
    ///
    /// All three fields have to go: leave the watchlist stamp behind and the
    /// title still reads as on the watchlist everywhere it's synced.
    /// Saving is the caller's business, since the favorites manager mutates
    /// under its own `@Query` context.
    static func clearFavoriteState(_ model: any FavoriteOrderable) {
        let state = state(model)
        clearFavoriteFields(model)
        syncWatchlists(model, trakt: state.trakt == true ? false : nil, simkl: state.simkl == true ? false : nil)
    }

    private static func clearFavoriteFields(_ model: any FavoriteOrderable) {
        // The viewer's decision, for iCloud sync — see `ContentClearLedger`.
        ContentClearLedger.shared.record(model.id)
        model.isFavorite = false
        model.favoriteOrder = nil
        (model as? any WatchlistFavoritable)?.addedToWatchlistDate = nil
    }

    /// Neither tracker represents IPTV channels. Services own id/connection
    /// guards and durable delivery; watched/unwatched actions stay independent.
    private static func syncWatchlists(_ model: any FavoriteOrderable, trakt: Bool?, simkl: Bool?) {
        if let movie = model as? Movie {
            if let trakt { TraktService.shared.syncWatchlist(movie: movie, watchlisted: trakt) }
            if let simkl { SimklService.shared.syncWatchlist(movie: movie, watchlisted: simkl) }
        } else if let series = model as? Series {
            if let trakt { TraktService.shared.syncWatchlist(series: series, watchlisted: trakt) }
            if let simkl { SimklService.shared.syncWatchlist(series: series, watchlisted: simkl) }
        }
    }
}

//
//  HomeView+HeroWarmStart.swift
//  Lume
//
//  First-frame hero state kept separate from HomeView's main layout.
//

import Foundation

extension HomeView {
    /// The playlist whose catalog and cached hero are currently shown.
    var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// The promoted row, if it is configured, still switched on, and — since
    /// every promotable row is a movie/series list (see
    /// `SectionSurface.defaultHeroSourceURL`; Sports isn't promotable) —
    /// the profile can browse at least one of those catalogs. Showing a hero
    /// that can't be opened is worse than showing none. See `vodAvailable`.
    var heroRef: HomeSectionRef? {
        guard vodAvailable,
              let ref = HomeLayoutSettings.heroRef(heroSectionRaw),
              HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
        else { return nil }
        return ref
    }

    private var heroWarmStartScope: String {
        HeroWarmStartCache.catalogScope(
            playlistID: activePlaylist?.id,
            visibilityToken: restriction.visibilityToken,
            hero: heroRef,
            customSections: customSections
        )
    }

    var heroWarmStartBackdropURL: URL? {
        heroWarmStart.backdropURL(hero: heroRef, catalogScope: heroWarmStartScope)
    }

    func rememberHeroWarmStart(_ backdropURL: URL?) {
        heroWarmStart.remember(backdropURL, hero: heroRef, catalogScope: heroWarmStartScope)
    }
}

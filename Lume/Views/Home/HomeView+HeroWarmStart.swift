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

    /// The promoted row, if it is configured and still switched on.
    var heroRef: HomeSectionRef? {
        guard let ref = HomeLayoutSettings.heroRef(heroSectionRaw),
              HomeLayoutSettings.isEnabled(ref, disabledRaw: disabledSectionsRaw)
        else { return nil }
        return ref
    }

    private var heroWarmStartScope: String {
        activePlaylist?.id.uuidString ?? "none"
    }

    var heroWarmStartBackdropURL: URL? {
        heroWarmStart.backdropURL(hero: heroRef, catalogScope: heroWarmStartScope)
    }

    func rememberHeroWarmStart(_ backdropURL: URL?) {
        heroWarmStart.remember(backdropURL, hero: heroRef, catalogScope: heroWarmStartScope)
    }
}

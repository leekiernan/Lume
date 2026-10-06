//
//  HomeView+Navigation.swift
//  Lume
//
//  Home's navigation stack, driven from `DeepLinkRouter` so a pushed detail
//  screen survives the tab being unmounted (see `IdleUnmountingTab`). Split out
//  of HomeView.swift, which sits at SwiftLint's file-length limit.
//

import SwiftUI

extension HomeView {
    /// Previews use a local path; the app's path outlives tab unmounting.
    var homePath: Binding<NavigationPath> {
        guard let pathRouter else { return $fallbackHomePath }
        return Binding(get: { pathRouter.homePath }, set: { pathRouter.homePath = $0 })
    }
}

/// Keep hero navigation value-driven, just like Home's poster links. An item
/// destination held in the tab's @State cannot survive activeOnly unmounting.
enum HomeHeroNavigation {
    static func appending(_ hero: HeroItem, to path: NavigationPath) -> NavigationPath {
        var path = path
        switch hero {
        case let .movie(movie, _, _, _, _): path.append(movie)
        case let .series(series, _, _, _, _): path.append(series)
        }
        return path
    }
}

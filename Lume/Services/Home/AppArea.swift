//
//  AppArea.swift
//  Lume
//
//  The browsable areas of the app — the entries in the top navigation, and the
//  axis the combined Library settings screen is organised by. Each area owns
//  whatever configuration makes sense for it: Home has configurable rows but no
//  categories, Live TV has categories but no rows, Movies and Series have both.
//
//  Deliberately separate from `AppTab` (which also covers Search and Settings,
//  neither of which is configurable) and from `SectionSurface` (which only
//  covers the surfaces that have rows).
//

import SwiftUI

nonisolated enum AppArea: String, CaseIterable, Identifiable {
    case home
    case movies
    case series
    case liveTV

    var id: String {
        rawValue
    }

    /// The area's configurable rows, or nil when it has none. Live TV is
    /// browsed by category rather than by row.
    var sectionSurface: SectionSurface? {
        switch self {
        case .home: .home
        case .movies: .movies
        case .series: .series
        case .liveTV: nil
        }
    }

    /// The catalog categories the area browses, or nil for Home, which draws
    /// from every category rather than owning any.
    var categoryType: CategoryType? {
        switch self {
        case .home: nil
        case .movies: .vod
        case .series: .series
        case .liveTV: .live
        }
    }

    var tab: AppTab {
        switch self {
        case .home: .home
        case .movies: .movies
        case .series: .series
        case .liveTV: .liveTV
        }
    }

    /// Matches the tab's own label, so the settings list reads the same as the
    /// navigation it configures.
    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .series: "Series"
        case .liveTV: "Live TV"
        }
    }

    /// The same label as a resolved `String`, for interpolation sites where a
    /// `LocalizedStringKey` can't be used. References the same catalog keys.
    var displayName: String {
        switch self {
        case .home: String(localized: "Home")
        case .movies: String(localized: "Movies")
        case .series: String(localized: "Series")
        case .liveTV: String(localized: "Live TV")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .movies: "film"
        case .series: "tv"
        case .liveTV: "antenna.radiowaves.left.and.right"
        }
    }
}

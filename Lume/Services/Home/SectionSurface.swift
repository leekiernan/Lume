//
//  SectionSurface.swift
//  Lume
//
//  The screens that are built out of configurable rows: Home, Movies and
//  Series. Each keeps its own row order, its own hidden set and its own custom
//  sections — a surface is the scope every layout preference is stored under —
//  while sharing one engine (`HomeLayoutSettings`, `CustomHomeSections`,
//  `SectionFeed`) so a change to how rows work lands on all three at once.
//

import SwiftUI

nonisolated enum SectionSurface: String, CaseIterable, Identifiable {
    case home
    case movies
    case series

    var id: String {
        rawValue
    }

    /// Prefix for this surface's UserDefaults keys. `home` deliberately keeps
    /// the raw value the Home-only build shipped, so existing layouts survive.
    var storagePrefix: String {
        rawValue
    }

    /// The media kind a row on this surface may show, or nil for Home, which
    /// mixes everything. Rows built from a remote list keep only entries of
    /// this kind, so a movie list dropped on the Series page simply resolves to
    /// nothing rather than showing the wrong medium.
    var mediaType: HomeListEntry.MediaType? {
        switch self {
        case .home: nil
        case .movies: .movie
        case .series: .series
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .series: "Series"
        }
    }

    /// The same label as a resolved `String`, for interpolation sites where a
    /// `LocalizedStringKey` can't be used. References the same catalog keys.
    var displayName: String {
        switch self {
        case .home: String(localized: "Home")
        case .movies: String(localized: "Movies")
        case .series: String(localized: "Series")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .movies: "film"
        case .series: "tv"
        }
    }
}

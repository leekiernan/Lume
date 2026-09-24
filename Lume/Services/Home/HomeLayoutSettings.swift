//
//  HomeLayoutSettings.swift
//  Lume
//
//  User preferences for a section surface's layout: which rows appear and in
//  what order, for Home, Movies and Series alike (see `SectionSurface`). The
//  order is a small scalar (a comma-separated list of section keys), so
//  UserDefaults (via @AppStorage) is the right home — mirroring the
//  `PlayerEnginePriority` ordering used for the playback engines.
//

import SwiftUI

/// A reorderable built-in row. The raw value is the stable key stored in the
/// user's section order, so cases must not be renamed once shipped. Not every
/// case applies to every surface — see `cases(for:)`.
enum HomeSection: String, CaseIterable, Identifiable {
    case recentlyWatched
    case favorites
    case recentlyAdded
    case forYou
    case trendingMovies
    case trendingSeries
    case traktWatchlist
    case sports

    var id: String {
        rawValue
    }

    /// The built-in rows a surface offers, in default order. Home mixes both
    /// media kinds and owns the recommendations row; the Movies and Series
    /// pages each take the trending row for their own medium, and add the
    /// "Recently Added" row their category browse used to carry.
    static func cases(for surface: SectionSurface) -> [HomeSection] {
        switch surface {
        case .home:
            [.recentlyWatched, .favorites, .forYou, .trendingMovies, .trendingSeries, .traktWatchlist]
        case .movies:
            [.recentlyWatched, .favorites, .recentlyAdded, .trendingMovies, .traktWatchlist]
        case .series:
            [.recentlyWatched, .favorites, .recentlyAdded, .trendingSeries, .traktWatchlist]
        }
    }

    /// The label shown in the layout settings. Mirrors the row's own header
    /// (the Trakt row is shortened from "From Your Trakt Watchlist").
    var title: LocalizedStringKey {
        switch self {
        case .recentlyWatched: "Recently Watched"
        case .favorites: "Favorites"
        case .recentlyAdded: "Recently Added"
        case .forYou: "For You"
        case .trendingMovies: "Trending Movies"
        case .trendingSeries: "Trending Series"
        case .traktWatchlist: "Trakt Watchlist"
        case .sports: "Sports"
        }
    }

    /// The same label as a resolved `String`, for places that interpolate it
    /// (e.g. accessibility labels) where a `LocalizedStringKey` can't be used.
    /// References the same catalog keys as `title`.
    var displayName: String {
        switch self {
        case .recentlyWatched: String(localized: "Recently Watched")
        case .favorites: String(localized: "Favorites")
        case .recentlyAdded: String(localized: "Recently Added")
        case .forYou: String(localized: "For You")
        case .trendingMovies: String(localized: "Trending Movies")
        case .trendingSeries: String(localized: "Trending Series")
        case .traktWatchlist: String(localized: "Trakt Watchlist")
        case .sports: String(localized: "Sports")
        }
    }

    /// Whether this row can be the hero. Only rows the shared feed resolves
    /// from a list qualify: the @Query-backed local rows are assembled by each
    /// page, so the feed that builds the hero never sees their items.
    var isPromotable: Bool {
        switch self {
        case .trendingMovies, .trendingSeries, .traktWatchlist: true
        case .recentlyWatched, .favorites, .recentlyAdded, .forYou, .sports: false
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyWatched: "clock.arrow.circlepath"
        case .favorites: "star"
        case .recentlyAdded: "plus.rectangle.on.rectangle"
        case .forYou: "sparkles"
        case .trendingMovies: "film"
        case .trendingSeries: "tv"
        case .traktWatchlist: "rectangle.stack.badge.play"
        case .sports: "sportscourt"
        }
    }
}

/// A row on a section surface: one of the built-in sections, or a user-added
/// custom section (`CustomHomeSection`) identified by its id. This is what the
/// stored order and the hidden set are lists of, so built-in and custom rows
/// interleave freely and hide the same way.
enum HomeSectionRef: Hashable, Identifiable {
    case builtin(HomeSection)
    case custom(UUID)

    /// Marks a custom section's token. `HomeSection` raw values are plain
    /// identifiers, so the prefix can never collide with one.
    private static let customPrefix = "custom:"

    var id: String {
        token
    }

    /// The stable string stored in the order / hidden lists.
    var token: String {
        switch self {
        case let .builtin(section): section.rawValue
        case let .custom(id): "\(Self.customPrefix)\(id.uuidString)"
        }
    }

    /// Parses a stored token, returning nil for anything unrecognised — a
    /// section removed from a newer build, or a malformed value.
    init?(token: String) {
        if token.hasPrefix(Self.customPrefix) {
            guard let uuid = UUID(uuidString: String(token.dropFirst(Self.customPrefix.count))) else { return nil }
            self = .custom(uuid)
        } else if let section = HomeSection(rawValue: token) {
            self = .builtin(section)
        } else {
            return nil
        }
    }

    var builtin: HomeSection? {
        if case let .builtin(section) = self { return section }
        return nil
    }

    var customID: UUID? {
        if case let .custom(id) = self { return id }
        return nil
    }

    /// Custom rows always qualify — they are a list by definition.
    var isPromotable: Bool {
        builtin?.isPromotable ?? true
    }
}

/// The order of a surface's rows, top to bottom. Each section still only
/// renders when it has something to show (and "For You" additionally honours
/// the recommendations toggle, see `RecommendationSettings`). Persisted as a
/// comma-separated list of `HomeSectionRef` tokens, one key per surface.
enum HomeLayoutSettings {
    /// Stored section order for `surface`. Empty until the user reorders, in
    /// which case `resolve` falls back to the surface's default order.
    static func sectionOrderKey(_ surface: SectionSurface) -> String {
        "\(surface.storagePrefix).sectionOrder.v1"
    }

    /// Rows the user has switched off on `surface`, as a comma-separated list
    /// of tokens. Absence means enabled, so the default (empty) shows every
    /// section. `.forYou` is intentionally NOT tracked here — its on/off state
    /// is the opt-in `RecommendationSettings.enabledKey`, which also gates the
    /// (expensive) recommendation recompute on Home.
    static func disabledSectionsKey(_ surface: SectionSurface) -> String {
        "\(surface.storagePrefix).disabledSections.v1"
    }

    /// Which row this surface shows as its hero, as a `HomeSectionRef` token.
    /// Empty means no hero. A promoted row is shown *only* as the hero, never
    /// also as a row.
    static func heroSectionKey(_ surface: SectionSurface) -> String {
        "\(surface.storagePrefix).heroSection.v1"
    }

    /// Set once the surface's starting hero has been created, so deleting it
    /// stays deleted rather than reappearing on the next launch.
    static func heroSeededKey(_ surface: SectionSurface) -> String {
        "\(surface.storagePrefix).heroSeeded.v1"
    }

    static func heroRef(_ raw: String) -> HomeSectionRef? {
        HomeSectionRef(token: raw)
    }

    static func decodeDisabled(_ raw: String) -> Set<HomeSectionRef> {
        Set(raw.split(separator: ",").compactMap { HomeSectionRef(token: String($0)) })
    }

    /// Encode the disabled set in a stable order so the stored value (and its
    /// iCloud-synced @AppStorage) doesn't churn as the set is mutated.
    static func encodeDisabled(_ sections: Set<HomeSectionRef>) -> String {
        sections.map(\.token).sorted().joined(separator: ",")
    }

    /// Whether `section` should render. Not meaningful for `.forYou` (see
    /// `disabledSectionsKey`); callers handle that case via `RecommendationSettings`.
    static func isEnabled(_ section: HomeSectionRef, disabledRaw: String) -> Bool {
        !decodeDisabled(disabledRaw).contains(section)
    }

    /// Flip one row's hidden state, returning the new encoded set.
    static func settingEnabled(
        _ isOn: Bool,
        for section: HomeSectionRef,
        disabledRaw: String
    ) -> String {
        var disabled = decodeDisabled(disabledRaw)
        if isOn { disabled.remove(section) } else { disabled.insert(section) }
        return encodeDisabled(disabled)
    }

    /// Decode the stored order into a complete, de-duplicated row list for
    /// `surface`, falling back to its default order when nothing has been
    /// stored yet. `custom` is the user's current custom sections for that same
    /// surface: refs to sections they've since deleted drop out, and newly
    /// added ones land at the end.
    static func resolve(
        orderRaw: String,
        custom: [CustomHomeSection],
        surface: SectionSurface
    ) -> [HomeSectionRef] {
        normalized(decode(orderRaw), custom: custom, surface: surface)
    }

    /// Parse the comma-separated raw value into rows, dropping any token that
    /// doesn't name a known section.
    static func decode(_ raw: String) -> [HomeSectionRef] {
        raw.split(separator: ",").compactMap { HomeSectionRef(token: String($0)) }
    }

    static func encode(_ list: [HomeSectionRef]) -> String {
        list.map(\.token).joined(separator: ",")
    }

    /// Keep the given order but ensure every row of `surface` appears exactly
    /// once: drop duplicates, custom refs with no matching section, and
    /// built-ins that don't belong to this surface, then append any row missing
    /// from the list — built-ins in the surface's default order, then custom
    /// sections in the order they were added. Guarantees the order is always
    /// complete even after a new case is added to `HomeSection`, or a section
    /// is added on another device, once the user has stored their order.
    static func normalized(
        _ order: [HomeSectionRef],
        custom: [CustomHomeSection],
        surface: SectionSurface
    ) -> [HomeSectionRef] {
        let customIDs = Set(custom.map(\.id))
        let builtins = HomeSection.cases(for: surface)
        var seen = Set<HomeSectionRef>()
        var result: [HomeSectionRef] = []
        for ref in order where seen.insert(ref).inserted {
            switch ref {
            case let .builtin(section) where !builtins.contains(section): continue
            case let .custom(id) where !customIDs.contains(id): continue
            default: result.append(ref)
            }
        }
        for section in builtins where seen.insert(.builtin(section)).inserted {
            result.append(.builtin(section))
        }
        for section in custom where seen.insert(.custom(section.id)).inserted {
            result.append(.custom(section.id))
        }
        return result
    }
}

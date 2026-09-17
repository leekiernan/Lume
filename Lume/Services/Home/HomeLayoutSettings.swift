//
//  HomeLayoutSettings.swift
//  Lume
//
//  User preferences for the Home screen layout: which rows appear and in what
//  order. The order is a small scalar (a comma-separated list of section keys),
//  so UserDefaults (via @AppStorage) is the right home — mirroring the
//  `PlayerEnginePriority` ordering used for the playback engines.
//

import SwiftUI

/// A reorderable row on the Home screen. The raw value is the stable key stored
/// in the user's section order, so cases must not be renamed once shipped.
enum HomeSection: String, CaseIterable, Identifiable {
    case recentlyWatched
    case favorites
    case forYou
    case trendingMovies
    case trendingSeries
    case traktWatchlist
    case sports

    var id: String {
        rawValue
    }

    /// The label shown in the Home layout settings. Mirrors the row's own header
    /// on Home (the Trakt row is shortened from "From Your Trakt Watchlist").
    var title: LocalizedStringKey {
        switch self {
        case .recentlyWatched: "Recently Watched"
        case .favorites: "Favorites"
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
        case .forYou: String(localized: "For You")
        case .trendingMovies: String(localized: "Trending Movies")
        case .trendingSeries: String(localized: "Trending Series")
        case .traktWatchlist: String(localized: "Trakt Watchlist")
        case .sports: String(localized: "Sports")
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyWatched: "clock.arrow.circlepath"
        case .favorites: "star"
        case .forYou: "sparkles"
        case .trendingMovies: "film"
        case .trendingSeries: "tv"
        case .traktWatchlist: "rectangle.stack.badge.play"
        case .sports: "sportscourt"
        }
    }
}

/// A row on the Home screen: one of the built-in sections, or a user-added
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
}

/// The order of the Home rows, top to bottom.as something to show (and "For You" additionally honours the
/// recommendations toggle, see `RecommendationSettings`). Persisted as a
/// comma-separated list of `HomeSection` raw values under `sectionOrderKey`.
enum HomeLayoutSettings {
    /// Stored section order. Empty until the user reorders, in which case
    /// `resolve` falls back to the declaration order of `HomeSection`.
    static let sectionOrderKey = "home.sectionOrder.v1"

    /// Sections the user has switched off, as a comma-separated list of raw
    /// values. Absence means enabled, so the default (empty) shows every
    /// section. `.forYou` is intentionally NOT tracked here — its on/off state
    /// is the opt-in `RecommendationSettings.enabledKey`, which also gates the
    /// (expensive) recommendation recompute on Home.
    static let disabledSectionsKey = "home.disabledSections.v1"

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

    /// Decode the stored order into a complete, de-duplicated row list, falling
    /// back to the declaration order when nothing has been stored yet. `custom`
    /// is the user's current custom sections: refs to sections they've since
    /// deleted drop out, and newly added ones land at the end.
    static func resolve(orderRaw: String, custom: [CustomHomeSection]) -> [HomeSectionRef] {
        normalized(decode(orderRaw), custom: custom)
    }

    /// Parse the comma-separated raw value into rows, dropping any token that
    /// doesn't name a known section.
    static func decode(_ raw: String) -> [HomeSectionRef] {
        raw.split(separator: ",").compactMap { HomeSectionRef(token: String($0)) }
    }

    static func encode(_ list: [HomeSectionRef]) -> String {
        list.map(\.token).joined(separator: ",")
    }

    /// Keep the given order but ensure every row appears exactly once: drop
    /// duplicates and custom refs with no matching section, then append any row
    /// missing from the list — built-ins in declaration order, then custom
    /// sections in the order they were added. Guarantees the order is always
    /// complete even after a new case is added to `HomeSection`, or a section is
    /// added on another device, once the user has stored their order.
    static func normalized(_ order: [HomeSectionRef], custom: [CustomHomeSection]) -> [HomeSectionRef] {
        let customIDs = Set(custom.map(\.id))
        var seen = Set<HomeSectionRef>()
        var result: [HomeSectionRef] = []
        for ref in order where seen.insert(ref).inserted {
            if let id = ref.customID, !customIDs.contains(id) { continue }
            result.append(ref)
        }
        for section in HomeSection.allCases where seen.insert(.builtin(section)).inserted {
            result.append(.builtin(section))
        }
        for section in custom where seen.insert(.custom(section.id)).inserted {
            result.append(.custom(section.id))
        }
        return result
    }
}

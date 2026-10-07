import Foundation

nonisolated enum LiveTVHubRow: String, CaseIterable, Identifiable {
    case recentlyWatched, favorites
    case unitedKingdom = "uk-essentials"
    case unitedStates = "us-essentials"
    case canada = "ca-essentials"
    case australia = "au-essentials"
    case newZealand = "nz-essentials"
    case southAfrica = "za-essentials"
    case startingSoon

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .recentlyWatched: String(localized: "Recently Watched")
        case .favorites: String(localized: "Favorites")
        case .unitedKingdom: String(localized: "UK Essentials")
        case .unitedStates: String(localized: "US Essentials")
        case .canada: String(localized: "Canadian Essentials")
        case .australia: String(localized: "Australian Essentials")
        case .newZealand: String(localized: "New Zealand Essentials")
        case .southAfrica: String(localized: "South African Essentials")
        case .startingSoon: String(localized: "Starting Soon")
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyWatched: "clock.arrow.circlepath"
        case .favorites: "heart"
        case .startingSoon: "bell"
        default: "globe"
        }
    }
}

nonisolated enum LiveTVHubLayout {
    static let baseOrderKey = "liveTV.sectionOrder.v1"
    static let baseHiddenKey = "liveTV.hiddenSections.v1"
    static func rows(orderRaw: String, hiddenRaw: String = "") -> [LiveTVHubRow] {
        let hidden = Set(SectionTokens.decode(hiddenRaw))
        return SectionTokens.ordered(orderRaw, available: LiveTVHubRow.allCases.map(\.id))
            .filter { !hidden.contains($0) }.compactMap(LiveTVHubRow.init(rawValue:))
    }
}

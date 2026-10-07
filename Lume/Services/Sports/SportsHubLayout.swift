//
//  SportsHubLayout.swift
//  Lume
//
//  Which follows the Sports hub leaves out of its rows. The order is the
//  follow list's own (`SportsFollowService`); hiding is separate, so a team can
//  come off the hub and still be followed — still on the Home shelf, still
//  alerting. Profile-scoped, like the rest of a profile's layout.
//

import Foundation

nonisolated enum SportsHubLayout {
    static let baseHiddenKey = "sports.hiddenFollows.v1"

    static var hiddenKey: String {
        ProfileScopedPreferences.key(baseHiddenKey)
    }

    /// Follow keys hold ":" and "/", never a newline.
    static func hidden(_ raw: String) -> Set<String> {
        Set(SectionTokens.decode(raw))
    }

    static func encode(_ keys: Set<String>) -> String {
        SectionTokens.encode(keys.sorted())
    }

    static func toggling(_ key: String, in raw: String) -> String {
        SectionTokens.toggling(key, in: raw)
    }
}

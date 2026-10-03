//
//  SportsChannelPreference.swift
//  Lume
//
//  Which of the channels carrying a game a Play press opens. The resolver's
//  tiers (a remembered pick first, then how well the guide matched) stay in
//  charge; within a tier, channels are ordered by what suits this viewer: one
//  in a preferred audio language before one that isn't, then the quality that
//  fits the screen — 4K on a 4K display, FHD on a 1080p one, where a UHD feed
//  only costs bandwidth and start-up time.
//
//  A channel's language is read off its name before it is opened, from the
//  prefixes IPTV lists use ("UK: …", "DE | …", "[EN] …"); prefixes that name
//  more than one language ("AR" is Argentina in some lists, Arabic in others)
//  are left unread.
//

import Foundation

nonisolated enum SportsChannelPreference {
    struct Context: Equatable {
        /// Bare codes in the viewer's order ("en", "de").
        var preferredLanguages: [String]
        var displayIs4K: Bool
    }

    /// `channels` in the resolver's order, re-ordered within each tier.
    static func ordered(_ channels: [ResolvedChannel], context: Context) -> [ResolvedChannel] {
        channels.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if left.source.rank != right.source.rank { return left.source.rank < right.source.rank }
            let leftLanguage = languageRank(left.stream.name, preferred: context.preferredLanguages)
            let rightLanguage = languageRank(right.stream.name, preferred: context.preferredLanguages)
            if leftLanguage != rightLanguage { return leftLanguage < rightLanguage }
            let leftFit = qualityFit(left.stream.name, displayIs4K: context.displayIs4K)
            let rightFit = qualityFit(right.stream.name, displayIs4K: context.displayIs4K)
            if leftFit != rightFit { return leftFit > rightFit }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    /// 0 for the first preferred language, 1 for the next…; an unreadable
    /// name sits after every preferred language but before a known other one,
    /// since most lists only prefix foreign channels.
    static func languageRank(_ name: String, preferred: [String]) -> Int {
        guard let language = language(ofChannelNamed: name) else { return preferred.count }
        return preferred.firstIndex(of: language) ?? preferred.count + 1
    }

    /// Higher is better for the display.
    static func qualityFit(_ name: String, displayIs4K: Bool) -> Int {
        switch sportsQualityBadge(from: name) {
        case "4K", "UHD": displayIs4K ? 3 : 1
        case "FHD": displayIs4K ? 2 : 3
        case "HD": 2
        default: displayIs4K ? 1 : 2
        }
    }

    /// The language a channel name's prefix names, if any.
    static func language(ofChannelNamed name: String) -> String? {
        let upper = name.uppercased()
        // "[EN] beIN", "(DE) Sky": a bracketed tag anywhere at the start.
        let trimmed = upper.trimmingCharacters(in: .whitespaces)
        var token: Substring?
        if let first = trimmed.first, first == "[" || first == "(" {
            token = trimmed.dropFirst().prefix { $0.isLetter }
        } else {
            // "UK: Sky", "DE | Sky", "US - ESPN", "FR- Canal+".
            let letters = trimmed.prefix { $0.isLetter }
            let rest = trimmed.dropFirst(letters.count).trimmingCharacters(in: .whitespaces)
            if (2 ... 3).contains(letters.count), let separator = rest.first, ":|-".contains(separator) {
                token = letters
            }
        }
        guard let token else { return nil }
        return prefixLanguages[String(token)]
    }

    /// Country and language prefixes that name one language unambiguously.
    private static let prefixLanguages: [String: String] = [
        "UK": "en", "GB": "en", "US": "en", "USA": "en", "IE": "en", "AU": "en", "CA": "en",
        "EN": "en", "ENG": "en",
        "DE": "de", "GER": "de", "AT": "de",
        "FR": "fr", "FRA": "fr",
        "ES": "es", "SPA": "es", "ESP": "es", "MX": "es",
        "IT": "it", "ITA": "it",
        "PT": "pt", "POR": "pt", "BR": "pt",
        "NL": "nl", "PL": "pl", "TR": "tr", "SE": "sv", "NO": "no", "DK": "da", "FI": "fi",
        "GR": "el", "RU": "ru", "JP": "ja", "KR": "ko"
    ]
}

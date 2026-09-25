//
//  SportsMatcher.swift
//  Lume
//
//  The token logic that ties a `SportsFixture` to programmes and channel names
//  in the user's own EPG: team/name tokenizing, text normalization and the
//  kickoff window. Pure, `nonisolated` logic over plain value types (no
//  SwiftData, no network), fully unit-testable. `SportsChannelResolver` does
//  the scoring and ranking on top of these primitives.
//

import Foundation

nonisolated enum SportsMatcher {
    /// How far before kickoff a broadcast may start (pre-match coverage) and how
    /// far after kickoff a listing may still begin and count as the same match.
    static let leadTime: TimeInterval = 2 * 3600
    static let lateStart: TimeInterval = 30 * 60

    /// Whole-word-ish containment: the token must be bounded by non-letters so
    /// "city" doesn't match inside "velocity". The haystack must already be
    /// normalized and space-padded by `normalize`.
    static func containsWord(_ token: String, in haystack: String) -> Bool {
        haystack.contains(" \(token) ")
    }

    /// Distinctive tokens for a fixture team: its ESPN display name, short name,
    /// its abbreviation (only when ≥3 letters, so "FC"/"AC" don't add noise) and
    /// its aliases, each tokenized and folded, unioned into one set.
    static func tokens(for team: SportsTeam, aliases: SportsTeamAliases = .bundled) -> Set<String> {
        var names = [team.name, team.shortName]
        if team.abbreviation.count >= 3 { names.append(team.abbreviation) }
        names.append(contentsOf: aliases.aliases(for: [team.name, team.shortName]))

        var result: Set<String> = []
        for name in names {
            result.formUnion(tokens(forName: name))
        }
        return result
    }

    /// Distinctive tokens for a single name string: folded, split on word
    /// boundaries, generic affixes and very short tokens dropped. Falls back to
    /// the longer raw tokens when filtering would leave nothing.
    static func tokens(forName name: String) -> Set<String> {
        let raw = normalize(name)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 }
        let meaningful = raw.filter { !stopwords.contains($0) }
        return Set(meaningful.isEmpty ? raw : meaningful)
    }

    /// Lowercases, strips diacritics, replaces every non-alphanumeric run with a
    /// space, and pads with leading/trailing spaces so `containsWord` can rely on
    /// word boundaries.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let collapsed = String(cleaned).split(separator: " ").joined(separator: " ")
        return " \(collapsed) "
    }

    /// Generic club affixes that don't distinguish one team from another. Kept
    /// minimal and safe: words like "real", "atletico" or "sporting" are left as
    /// tokens because they're often the *distinguishing* part. Two-letter affixes
    /// (fc, ac, cf…) are already dropped by the length filter. Lowercase and
    /// accent-free to match `normalize` output.
    private static let stopwords: Set<String> = [
        "afc", "ssc", "club", "calcio", "football", "fussball"
    ]
}

/// Bundled team-alias table: provider names/keys → alternate names and exonyms
/// in the app's languages (Napoli → Neapel, Inter Milan → Inter, …). Shipped as
/// `SportsTeamAliases.json`; matching folds each alias through the same
/// tokenizer as a team's own names.
nonisolated struct SportsTeamAliases {
    /// Folded team key → its alias strings.
    private let byKey: [String: [String]]

    init(rawEntries: [String: [String]]) {
        var map: [String: [String]] = [:]
        for (key, values) in rawEntries {
            map[SportsTeamAliases.foldKey(key)] = values
        }
        byKey = map
    }

    /// Aliases for any of `names` (a team's display and short names), deduped.
    func aliases(for names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            for alias in byKey[SportsTeamAliases.foldKey(name)] ?? [] where seen.insert(alias).inserted {
                result.append(alias)
            }
        }
        return result
    }

    /// The lazily loaded, cached table shipped in the app bundle.
    static let bundled = load()

    static func load(bundle: Bundle = .main) -> SportsTeamAliases {
        let candidates = [bundle] + Bundle.allBundles
        for candidate in candidates {
            guard let url = candidate.url(forResource: "SportsTeamAliases", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
            else { continue }
            return SportsTeamAliases(rawEntries: decoded)
        }
        return SportsTeamAliases(rawEntries: [:])
    }

    /// Diacritic/case-folded, whitespace-collapsed key for dictionary lookup.
    private static func foldKey(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}

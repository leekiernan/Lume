import Foundation

/// Offline candidate rules, deliberately NOT connected to app publication.
/// Reuses the Sports hub's normalization and reviewed team aliases. Matching
/// programmes is a stronger claim than suggesting channels for a fixture.
nonisolated enum EPGSportsProgrammeIdentity {
    enum Kind: String, Codable { case strict, studio, teams, conflict, unresolved }

    struct Decision: Codable, Equatable {
        let kind: Kind
        let reasons: [String]

        var isCandidate: Bool {
            kind == .studio || kind == .teams
        }
    }

    struct Evidence {
        let headline: String
        let body: String
        let years: Set<String>
        let rounds: [String: Set<String>]
        let episodes: Set<String>
        let seasons: Set<String>
        let live: Bool
        let replay: Bool
        let competitions: Set<String>

        init(_ programme: ParsedProgramme) {
            headline = SportsMatcher.normalize(Self.unbadge(programme.title) + " " + (programme.subtitle ?? ""))
            let body = SportsMatcher.normalize(Self.unbadge(programme.title) + " " + (programme.subtitle ?? "") + " " + programme.description)
            self.body = body
            years = Self.seasonYears(body)
            rounds = Self.numberedRounds(body)
            episodes = Set(EPGSportsProgrammeIdentity.captures(#"(?:\bepisode\s*|\be|\bs\d+\s*e)(\d+)\b"#, in: body).map { $0[0] })
            seasons = Set(EPGSportsProgrammeIdentity.captures(#"\bs(\d+)(?:\b|e\d+\b)"#, in: body).map { $0[0] })
            live = programme.title.contains("ᴸᶦᵛᵉ") || SportsMatcher.containsWord("live", in: headline)
            replay = ["highlights", "classic", "classics", "replay", "repeat"].contains { SportsMatcher.containsWord($0, in: body) }
            competitions = Set(EPGSportsProgrammeIdentity.competitions.compactMap { key, phrases in
                phrases.contains(where: { body.contains(" \($0) ") }) ? key : nil
            })
        }

        static func unbadge(_ value: String) -> String {
            var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while let badge = ["ᴺᵉʷ", "ᴸᶦᵛᵉ"].first(where: { value.hasSuffix($0) }) {
                value.removeLast(badge.count)
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return value
        }

        private static func seasonYears(_ value: String) -> Set<String> {
            // SportsMatcher normalizes 2009/10, 2009–10 and 2009-2010 alike.
            var years = Set(EPGSportsProgrammeIdentity.captures(#"\b((?:19|20)\d{2})\b"#, in: value).map { $0[0] })
            for parts in EPGSportsProgrammeIdentity.captures(#"\b((?:19|20)\d{2}) (\d{2})\b"#, in: value) {
                guard let start = Int(parts[0]), let suffix = Int(parts[1]), (start + 1) % 100 == suffix else { continue }
                years.insert(String(start + 1))
            }
            return years
        }

        private static func numberedRounds(_ value: String) -> [String: Set<String>] {
            let ordinals = ["first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5"]
            let pattern = #"\b(first|second|third|fourth|fifth|\d+(?:st|nd|rd|th)?) (t20|test|odi|round|leg)\b"#
            var rounds: [String: Set<String>] = [:]
            for parts in EPGSportsProgrammeIdentity.captures(pattern, in: value) {
                let number = ordinals[parts[0]] ?? parts[0].filter(\.isNumber)
                rounds[parts[1], default: []].insert(number)
            }
            for parts in EPGSportsProgrammeIdentity.captures(#"\b(matchday|round|leg) (\d+)\b"#, in: value) {
                rounds[parts[0], default: []].insert(parts[1])
            }
            return rounds
        }
    }

    /// Station identity and unique interval pairing are checked by the caller.
    /// Raw provider programmes are inputs, never already-enriched listings.
    static func compare(_ provider: ParsedProgramme, _ external: ParsedProgramme, aliases: SportsTeamAliases) -> Decision {
        guard provider.start == external.start, provider.end == external.end, provider.end > provider.start else {
            return Decision(kind: .unresolved, reasons: ["exact interval required"])
        }
        let primary = Evidence(provider)
        let secondary = Evidence(external)
        let conflicts = conflicts(primary, secondary)
        guard conflicts.isEmpty else { return Decision(kind: .conflict, reasons: conflicts) }
        if EPGProgrammeEnrichment.normalizedTitle(provider.title) == EPGProgrammeEnrichment.normalizedTitle(external.title) {
            return Decision(kind: .strict, reasons: ["existing exact title and interval"])
        }
        if let studio = studioName(provider.title), studio == studioName(external.title) {
            return Decision(kind: .studio, reasons: ["reviewed studio programme: \(studio)", "exact interval; no detected conflicts"])
        }
        return compareTeams(provider, external, primary: primary, secondary: secondary, aliases: aliases)
    }

    private static func conflicts(_ primary: Evidence, _ secondary: Evidence) -> [String] {
        var reasons: [String] = []
        if primary.live && secondary.replay || secondary.live && primary.replay { reasons.append("live/replay conflict") }
        if primary.live && primary.replay || secondary.live && secondary.replay { reasons.append("internally conflicting live/replay cues") }
        if !primary.years.isEmpty, !secondary.years.isEmpty, primary.years.isDisjoint(with: secondary.years) { reasons.append("year/season conflict") }
        if !primary.episodes.isEmpty, !secondary.episodes.isEmpty, primary.episodes.isDisjoint(with: secondary.episodes) { reasons.append("episode conflict") }
        if !primary.seasons.isEmpty, !secondary.seasons.isEmpty, primary.seasons.isDisjoint(with: secondary.seasons) { reasons.append("series season conflict") }
        for key in primary.rounds.keys.sorted() {
            if let left = primary.rounds[key], let right = secondary.rounds[key], left.isDisjoint(with: right) {
                reasons.append("\(key) number conflict")
            }
        }
        if !primary.competitions.isEmpty, !secondary.competitions.isEmpty, primary.competitions.isDisjoint(with: secondary.competitions) {
            reasons.append("competition conflict")
        }
        return reasons
    }

    private static func compareTeams(_ provider: ParsedProgramme, _ external: ParsedProgramme, primary: Evidence, secondary: Evidence, aliases: SportsTeamAliases) -> Decision {
        guard let left = teams(in: provider), let right = teams(in: external) else {
            return Decision(kind: .unresolved, reasons: ["no explicit two-team fixture in both headlines"])
        }
        let matches = sameTeam(left.0, right.0, aliases: aliases) && sameTeam(left.1, right.1, aliases: aliases)
            || sameTeam(left.0, right.1, aliases: aliases) && sameTeam(left.1, right.0, aliases: aliases)
        guard matches else { return Decision(kind: .conflict, reasons: ["different or unrecognised team pair"]) }
        guard !sameTeam(left.0, left.1, aliases: aliases), !sameTeam(right.0, right.1, aliases: aliases) else {
            return Decision(kind: .unresolved, reasons: ["team aliases do not distinguish opponents"])
        }
        let shared = primary.competitions.intersection(secondary.competitions)
        guard shared.count == 1 else { return Decision(kind: .unresolved, reasons: ["one shared competition required"]) }
        // Replays need a positively corroborated year/season. Live matches need
        // both sources to say live; absence of a replay cue is not proof of live.
        let year = !primary.years.isDisjoint(with: secondary.years)
        let live = primary.live && secondary.live && !primary.replay && !secondary.replay
        guard year || live else { return Decision(kind: .unresolved, reasons: ["fixture needs shared year/season or explicit live on both sources"]) }
        let reasons = ["both full team names or reviewed aliases", "shared competition: \(shared.sorted().joined(separator: ", "))",
                       year ? "shared year/season" : "both explicitly live"]
        return Decision(kind: .teams, reasons: reasons)
    }

    private static let studios: Set<String> = [
        "good morning football", "nfl gameday", "total football", "premier league preview",
        "tnt sports reload", "inside serie a", "the football show"
    ]

    private static func studioName(_ title: String) -> String? {
        let value = SportsMatcher.normalize(Evidence.unbadge(title)).trimmingCharacters(in: .whitespaces)
        if studios.contains(value) { return value }
        for name in studios.sorted() where value.hasPrefix(name + " ") {
            let suffix = String(value.dropFirst(name.count + 1))
            if suffix.range(of: #"^(?:episode|matchday) \d+$"#, options: .regularExpression) != nil { return name }
        }
        return nil
    }

    private static let competitions: [String: [String]] = [
        "efl": ["efl", "english football league"],
        "urc": ["united rugby championship", "urc"],
        "ucl": ["uefa champions league", "champions league"],
        "epl": ["premier league"], "nfl": ["nfl", "national football league"],
        "international-t20": ["international t20", "t20 international"],
        "test-cricket": ["test cricket"], "odi": ["one day international", "odi"]
    ]

    private static func teams(in programme: ParsedProgramme) -> (String, String)? {
        var result: (String, String)?
        for field in [programme.title, programme.subtitle ?? ""] {
            let tail = Evidence.unbadge(field).components(separatedBy: ":").last ?? ""
            guard captures(#"(?i)\s+(v\.?|vs\.?|versus|at|@)\s+"#, in: tail).count <= 1 else { return nil }
            let pairs = captures(#"(?i)^\s*(.+?)\s+(?:v\.?|vs\.?|versus|at|@)\s+(.+?)\s*$"#, in: tail)
            guard let pair = pairs.first else { continue }
            let clean: (String) -> String = { value in
                value.replacingOccurrences(of: #"(?i)\s+(?:(?:from|in|on)\s+.*|\d.*)$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let left = clean(pair[0]), right = clean(pair[1])
            guard !left.isEmpty, !right.isEmpty else { continue }
            if let previous = result {
                let previousNames = Set([previous.0, previous.1].map(SportsMatcher.normalize))
                guard previousNames == Set([left, right].map(SportsMatcher.normalize)) else { return nil }
            }
            result = (left, right)
        }
        return result
    }

    private static func sameTeam(_ left: String, _ right: String, aliases: SportsTeamAliases) -> Bool {
        let ambiguous: Set = ["city", "united", "athletic", "sporting", "madrid", "rangers"]
        let names: (String) -> Set<String> = { name in
            Set(([name] + aliases.aliases(for: [name])).map {
                SportsMatcher.normalize($0).trimmingCharacters(in: .whitespaces)
            }).subtracting(ambiguous)
        }
        return !names(left).isDisjoint(with: names(right))
    }

    private static func captures(_ pattern: String, in value: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = value as NSString
        return expression.matches(in: value, range: NSRange(location: 0, length: text.length)).map { match in
            (1 ..< match.numberOfRanges).map { text.substring(with: match.range(at: $0)) }
        }
    }
}

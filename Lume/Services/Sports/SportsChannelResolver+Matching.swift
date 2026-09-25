//
//  SportsChannelResolver+Matching.swift
//  Lume
//
//  What a fixture is recognised by in the guide and in channel names, and how
//  a programme scores against it: a match on both teams, a competitor-less
//  event on its name. Race sessions and tour-wide umbrella blocks have their
//  own matchers (`+Racing`, `+Competition`).
//

import Foundation

nonisolated extension SportsChannelResolver {
    /// What a fixture is recognised by in the guide and in channel names.
    enum MatchTarget {
        /// A match: both teams must be named.
        case teams(home: Set<String>, away: Set<String>)
        /// A competitor-less event (an F1 session, a UFC card): every token of
        /// one of its names must be named. Only names of two or more tokens
        /// qualify — a lone "italian" would match any cookery show at 3 pm.
        case event(names: [Set<String>])

        /// The tokens a candidate must contain at least one of.
        var seedTokens: Set<String> {
            switch self {
            case let .teams(home, _): home
            case let .event(names): names.reduce(into: []) { $0.formUnion($1) }
            }
        }
    }

    static func target(for fixture: SportsFixture) -> MatchTarget? {
        if let home = fixture.home?.team, let away = fixture.away?.team {
            let homeTokens = SportsMatcher.tokens(for: home)
            let awayTokens = SportsMatcher.tokens(for: away)
            guard !homeTokens.isEmpty, !awayTokens.isEmpty else { return nil }
            return .teams(home: homeTokens, away: awayTokens)
        }
        guard !fixture.hasTeams else { return nil }
        let names = [fixture.name, fixture.shortName]
            .compactMap(\.self)
            .map(SportsMatcher.tokens(forName:))
            .filter { $0.count >= 2 }
        return names.isEmpty ? nil : .event(names: names)
    }

    /// The best EPG signal for one channel and fixture.
    struct EPGHit {
        let score: Int
        let inOneField: Bool
        /// Both teams were found only in the description — a conference.
        let descriptionOnly: Bool
        let title: String
        let start: Date
    }

    static func isPresent(_ target: MatchTarget, in haystack: String) -> Bool {
        switch target {
        case let .teams(home, away):
            teamPresent(home, in: haystack) && teamPresent(away, in: haystack)
        case let .event(names):
            names.contains { allPresent($0, in: haystack) }
        }
    }

    /// The best-scoring EPG programme for a channel within the kickoff window,
    /// or `nil` when none names the fixture. For a match, `inOneField` is set
    /// when both teams appear together in the title or the sub-title (the
    /// fixture line), the stronger tier; a programme that names them only in its
    /// description — a conference — still qualifies, as the weakest EPG tier.
    /// An event is matched on its title and sub-title only.
    static func bestEPGHit(
        in candidates: [NormalizedCandidate],
        target: MatchTarget,
        kickoff: Date
    ) -> EPGHit? {
        let windowStart = kickoff.addingTimeInterval(-SportsMatcher.leadTime)
        let windowEnd = kickoff.addingTimeInterval(SportsMatcher.lateStart)

        var best: EPGHit?
        for candidate in candidates {
            guard candidate.start >= windowStart, candidate.start <= windowEnd else { continue }
            let hit: EPGHit? = switch target {
            case let .teams(home, away):
                teamsHit(candidate, home: home, away: away)
            case let .event(names):
                names.compactMap { eventHit(candidate, tokens: $0) }
                    .max { isBetterHit($1, than: $0, kickoff: kickoff) }
            }
            if let hit, isBetterHit(hit, than: best, kickoff: kickoff) { best = hit }
        }
        return best
    }

    static func teamsHit(_ candidate: NormalizedCandidate, home: Set<String>, away: Set<String>) -> EPGHit? {
        let title = candidate.normalizedTitle
        let subtitle = candidate.normalizedSubtitle
        let description = candidate.normalizedDescription

        let homeInTitle = teamPresent(home, in: title)
        let homeInSub = teamPresent(home, in: subtitle)
        let awayInTitle = teamPresent(away, in: title)
        let awayInSub = teamPresent(away, in: subtitle)
        let homeInHeadline = homeInTitle || homeInSub
        let awayInHeadline = awayInTitle || awayInSub
        let homeInBody = homeInHeadline || teamPresent(home, in: description)
        let awayInBody = awayInHeadline || teamPresent(away, in: description)
        guard homeInBody, awayInBody else { return nil }

        let inOneField = (homeInTitle && awayInTitle) || (homeInSub && awayInSub)
        let descriptionOnly = !(homeInHeadline && awayInHeadline)
        let score = (homeInSub ? subtitleWeight : 0) + (awayInSub ? subtitleWeight : 0)
            + (homeInTitle ? titleWeight : 0) + (awayInTitle ? titleWeight : 0)
            + (descriptionOnly ? descriptionWeight : 0)
        return EPGHit(
            score: score,
            inOneField: inOneField,
            descriptionOnly: descriptionOnly,
            title: candidate.title,
            start: candidate.start
        )
    }

    /// An event programme names every token of one of the event's names across
    /// its title and sub-title ("F1: Italian Grand Prix" / "Qualifying").
    static func eventHit(_ candidate: NormalizedCandidate, tokens: Set<String>) -> EPGHit? {
        let title = candidate.normalizedTitle
        let subtitle = candidate.normalizedSubtitle
        var score = 0
        for token in tokens {
            let inTitle = SportsMatcher.containsWord(token, in: title)
            let inSub = SportsMatcher.containsWord(token, in: subtitle)
            guard inTitle || inSub else { return nil }
            score += (inSub ? subtitleWeight : 0) + (inTitle ? titleWeight : 0)
        }
        return EPGHit(
            score: score,
            inOneField: allPresent(tokens, in: title) || allPresent(tokens, in: subtitle),
            descriptionOnly: false,
            title: candidate.title,
            start: candidate.start
        )
    }

    static func isBetterHit(_ lhs: EPGHit, than rhs: EPGHit?, kickoff: Date) -> Bool {
        guard let rhs else { return true }
        if lhs.descriptionOnly != rhs.descriptionOnly { return !lhs.descriptionOnly }
        if lhs.inOneField != rhs.inOneField { return lhs.inOneField }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return abs(lhs.start.timeIntervalSince(kickoff)) < abs(rhs.start.timeIntervalSince(kickoff))
    }

    /// A team is present when any distinctive token appears as a whole word.
    /// `haystack` must already be `SportsMatcher.normalize`d (space-padded).
    static func teamPresent(_ tokens: Set<String>, in haystack: String) -> Bool {
        tokens.contains { SportsMatcher.containsWord($0, in: haystack) }
    }

    static func allPresent(_ tokens: Set<String>, in haystack: String) -> Bool {
        tokens.allSatisfy { SportsMatcher.containsWord($0, in: haystack) }
    }
}

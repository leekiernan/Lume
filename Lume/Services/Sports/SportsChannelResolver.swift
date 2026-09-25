//
//  SportsChannelResolver.swift
//  Lume
//
//  Resolves a batch of `SportsFixture`s to the channels in the viewer's own
//  playlists that carry them, entirely off the main thread. Modelled on
//  `ChannelEPGLoader`/`EPGGuideLoader`: it runs on its own `ModelContext` inside
//  a detached task, bounds every fetch, and returns plain `Sendable` value
//  snapshots so nothing managed crosses back to the caller.
//
//  Three passes, in this order because each is cheaper than the last only once
//  the earlier ones have narrowed the work:
//   1. One scoped fetch of candidate `LiveStream`s across *all* playlists —
//      hidden channels and parental-/user-restricted categories excluded in
//      SQLite, not in Swift.
//   2. One `EPGListing` fetch, bounded by the union kickoff window *and* the
//      candidate channel ids, with the wide `listingDescription` column left
//      out — never the unscoped time-only scan that froze the guide.
//   3. Matching in Swift on `SportsMatcher`'s tokens (both teams for a match,
//      the event name for a race session or fight card), plus the viewer's
//      remembered picks and a channel-name fallback. A word index built once
//      per resolve limits each fixture to the channels sharing a word with it.
//

import Foundation
import SwiftData

// MARK: - Result value types

/// Why a channel was offered for a fixture, ordered by confidence. Its `rank`
/// is the sort key — a lower rank is a stronger signal.
nonisolated enum ResolvedChannelSource: String, Codable, Hashable {
    /// The viewer pinned this channel for the competition.
    case userPick
    /// The EPG programme names both teams together in its title or sub-title —
    /// the fixture line itself.
    case epgTitleSubtitle
    /// The EPG programme names both teams, but split across the title and
    /// sub-title rather than together in one field.
    case epgSingleField
    /// The programme's description names both teams — a multi-game
    /// conference ("Sonntags-Konferenz, 6. Spieltag") whose title says nothing
    /// about this fixture but whose body lists it among the games carried.
    case epgDescription
    /// No EPG match; the channel's own name names both teams
    /// ("DAZN 5 | Bayern vs Dortmund").
    case channelName

    var rank: Int {
        switch self {
        case .userPick: 0
        case .epgTitleSubtitle: 1
        case .epgSingleField: 2
        case .epgDescription: 3
        case .channelName: 4
        }
    }
}

/// A plain snapshot of the fields a resolved channel row needs — enough to
/// render the picker and to re-fetch the `LiveStream` by `id` when the viewer
/// chooses to watch.
nonisolated struct ResolvedStreamSummary: Codable, Hashable {
    let id: String
    let name: String
    let streamIcon: String?
    let epgChannelId: String?
}

/// One channel that can carry a fixture, with why and how well it matched.
nonisolated struct ResolvedChannel: Codable, Hashable, Identifiable {
    let stream: ResolvedStreamSummary
    let playlistID: UUID
    /// The matched EPG programme's title, when the match came from the guide.
    let matchedTitle: String?
    /// The matched programme's start, when known.
    let matchedStart: Date?
    /// Weighted match score, used to order channels within a `source` tier.
    let score: Int
    let source: ResolvedChannelSource
    /// True only when this is the single channel at the strongest tier for its
    /// fixture — the one case a live card offers one-tap playback.
    var isConfident: Bool

    var id: String {
        stream.id
    }
}

// MARK: - Resolver

nonisolated enum SportsChannelResolver {
    /// A visible channel plus what matching reads of it, derived once in pass 1
    /// so a wide fixture batch doesn't re-fold the same names per fixture: the
    /// pre-normalised name the channel-name fallback matches against, and the
    /// key remembered picks are stored under.
    private struct Channel {
        let summary: ResolvedStreamSummary
        let playlistID: UUID
        let nameHaystack: String
        let pickKey: String
    }

    /// The `EPGListing` fetch shape, exposed for the query-shape contract test.
    /// Bounded by the kickoff window *and* the candidate channel ids. Unlike the
    /// guide loaders it does fetch `listingDescription`: a conference programme
    /// only names its games there, and the window keeps the row count small.
    nonisolated static func epgCandidateDescriptor(
        channelIds: [String],
        windowStart: Date,
        windowEnd: Date
    ) -> FetchDescriptor<EPGListing> {
        var descriptor = FetchDescriptor<EPGListing>(
            predicate: #Predicate {
                channelIds.contains($0.channelId) && $0.start < windowEnd && $0.end > windowStart
            },
            sortBy: [SortDescriptor(\.channelId), SortDescriptor(\.start)]
        )
        descriptor.propertiesToFetch = [
            \.channelId, \.title, \.subtitle, \.listingDescription, \.start, \.end
        ]
        return descriptor
    }

    /// The candidate-channel fetch shape: every visible channel across all
    /// playlists, hidden channels and excluded categories dropped in SQLite.
    nonisolated static func candidateStreamDescriptor(
        restriction: ContentRestriction
    ) -> FetchDescriptor<LiveStream> {
        // Optionals so the predicate can test the optional `categoryId` directly
        // against the excluded set — the pattern `LiveChannelNavigator` uses.
        let excluded = Set(restriction.excludedCategoryIDs.map(String?.some))
        let filters = !excluded.isEmpty
        var descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate {
                !$0.isHidden && (!filters || $0.categoryId == nil || !excluded.contains($0.categoryId))
            }
        )
        descriptor.propertiesToFetch = [\.id, \.name, \.streamIcon, \.epgChannelId, \.categoryId]
        return descriptor
    }

    /// Resolves `fixtures` to the channels carrying them, keyed by `fixture.id`.
    ///
    /// `restriction` defaults to permissive so the two-pass fetch is callable in
    /// isolation; the hub passes the active viewer's restriction so a child
    /// profile never sees a locked category's channel. `picks` is read once, up
    /// front, into a `Sendable` snapshot so no `UserDefaults`-bearing value has
    /// to cross into the detached task.
    ///
    /// Results aren't shared across surfaces: a cache would need invalidating
    /// on every guide refresh, channel sync, pick and restriction change.
    nonisolated static func resolve(
        container: ModelContainer,
        fixtures: [SportsFixture],
        restriction: ContentRestriction = ContentRestriction(),
        picks: SportsChannelPicks = SportsChannelPicks()
    ) async -> [String: [ResolvedChannel]] {
        // A finished game has nothing left to watch; skip it before the guide scan.
        let fixtures = fixtures.filter { $0.status.state != .final }
        guard let firstKickoff = fixtures.map(\.startDate).min(),
              let lastKickoff = fixtures.map(\.startDate).max() else { return [:] }
        let pickIndex = picks.snapshot()

        return await Task.detached(priority: .utility) {
            let interval = Perf.begin(.sportsChannelResolve)
            defer { Perf.end(interval) }

            let context = ModelContext(container)

            // Pass 1 — candidate channels across all playlists.
            let streams = (try? context.fetch(candidateStreamDescriptor(restriction: restriction))) ?? []
            guard !streams.isEmpty else { return [:] }
            let (channels, channelIds) = buildChannels(from: streams)

            // Pass 2 — one bounded EPG fetch over the union kickoff window.
            let guide = buildGuide(
                context: context,
                channelIds: channelIds,
                windowStart: firstKickoff.addingTimeInterval(-SportsMatcher.leadTime),
                windowEnd: lastKickoff.addingTimeInterval(SportsMatcher.lateStart)
            )
            let index = CandidateIndex(channels: channels, guide: guide, pickIndex: pickIndex)

            // Pass 3 — match each fixture in Swift, against only the channels
            // that could possibly match it.
            var result: [String: [ResolvedChannel]] = [:]
            for fixture in fixtures {
                result[fixture.id] = resolveOne(
                    fixture: fixture,
                    channels: channels,
                    guide: guide,
                    index: index
                )
            }
            return result
        }.value
    }

    /// Maps candidate `LiveStream`s to `Channel`s (with normalized name
    /// haystacks and pick keys) and collects their non-empty EPG channel ids for
    /// the Pass 2 fetch.
    private nonisolated static func buildChannels(
        from streams: [LiveStream]
    ) -> (channels: [Channel], channelIds: Set<String>) {
        var channels: [Channel] = []
        channels.reserveCapacity(streams.count)
        var channelIds: Set<String> = []
        for stream in streams {
            guard let playlistID = UUID(uuidString: String(stream.id.prefix(36))) else { continue }
            channels.append(Channel(
                summary: ResolvedStreamSummary(
                    id: stream.id,
                    name: stream.name,
                    streamIcon: stream.streamIcon,
                    epgChannelId: stream.epgChannelId
                ),
                playlistID: playlistID,
                nameHaystack: SportsMatcher.normalize(stream.name),
                pickKey: SportsChannelPicks.channelKey(epgChannelId: stream.epgChannelId, name: stream.name)
            ))
            if let cid = stream.epgChannelId, !cid.isEmpty { channelIds.insert(cid) }
        }
        return (channels, channelIds)
    }

    /// An EPG candidate with its title, subtitle and the head of its description
    /// normalized once at guide-build time, so `bestEPGHit` reuses them across
    /// every fixture sharing the channel rather than re-normalizing per fixture.
    private struct NormalizedCandidate {
        let title: String
        let normalizedTitle: String
        let normalizedSubtitle: String
        let normalizedDescription: String
        let start: Date
    }

    /// How much of a description is searched. A conference body lists its games
    /// up front ("Der 6. Spieltag mit Hannover 96 - VfL Bochum, …"); the tail is
    /// commentators and filler.
    private static let descriptionScanLength = 400

    /// Runs the bounded EPG fetch and groups the listings by channel id, folding
    /// each listing's title and subtitle once.
    private nonisolated static func buildGuide(
        context: ModelContext,
        channelIds: Set<String>,
        windowStart: Date,
        windowEnd: Date
    ) -> [String: [NormalizedCandidate]] {
        guard !channelIds.isEmpty else { return [:] }
        let listings = (try? context.fetch(epgCandidateDescriptor(
            channelIds: Array(channelIds), windowStart: windowStart, windowEnd: windowEnd
        ))) ?? []
        var guide: [String: [NormalizedCandidate]] = [:]
        for listing in listings {
            guide[listing.channelId, default: []].append(NormalizedCandidate(
                title: listing.title,
                normalizedTitle: SportsMatcher.normalize(listing.title),
                normalizedSubtitle: SportsMatcher.normalize(listing.subtitle ?? ""),
                normalizedDescription: SportsMatcher.normalize(
                    String(listing.listingDescription.prefix(descriptionScanLength))
                ),
                start: listing.start
            ))
        }
        return guide
    }

    // MARK: - Candidate index

    /// Word → channel lookups built once per resolve, so each fixture examines
    /// only the channels sharing a word with it instead of every channel in
    /// every playlist. A match needs a fixture token present as a whole word in
    /// a normalized haystack, and a normalized haystack is exactly its
    /// space-separated words — so indexing those words drops no channel that
    /// could have matched, and the results are identical to a full scan.
    private struct CandidateIndex {
        /// Channel indices whose own name contains the word.
        let byNameWord: [String: [Int]]
        /// Channel indices whose guide window has a listing containing the word
        /// in its title, sub-title or scanned description.
        let byGuideWord: [String: Set<Int>]
        /// Channel indices by the key a remembered pick names them by.
        let byPickKey: [String: [Int]]
        let pickIndex: [String: String]

        init(channels: [Channel], guide: [String: [NormalizedCandidate]], pickIndex: [String: String]) {
            var byName: [String: [Int]] = [:]
            var byEPGId: [String: [Int]] = [:]
            var byPick: [String: [Int]] = [:]
            for (offset, channel) in channels.enumerated() {
                for word in Set(Self.words(channel.nameHaystack)) {
                    byName[word, default: []].append(offset)
                }
                if let cid = channel.summary.epgChannelId, guide[cid] != nil {
                    byEPGId[cid, default: []].append(offset)
                }
                byPick[channel.pickKey, default: []].append(offset)
            }
            var byGuide: [String: Set<Int>] = [:]
            for (cid, offsets) in byEPGId {
                var words: Set<String> = []
                for candidate in guide[cid] ?? [] {
                    words.formUnion(Self.words(candidate.normalizedTitle))
                    words.formUnion(Self.words(candidate.normalizedSubtitle))
                    words.formUnion(Self.words(candidate.normalizedDescription))
                }
                for word in words {
                    byGuide[word, default: []].formUnion(offsets)
                }
            }
            byNameWord = byName
            byGuideWord = byGuide
            byPickKey = byPick
            self.pickIndex = pickIndex
        }

        private static func words(_ haystack: String) -> [String] {
            haystack.split(separator: " ").map(String.init)
        }

        /// Every channel that could match a fixture seeded by `tokens` or picked
        /// for `competitionKey`, in pass-1 order.
        func candidates(seedTokens: Set<String>, competitionKey: String) -> [Int] {
            var result: Set<Int> = []
            for token in seedTokens {
                result.formUnion(byNameWord[token] ?? [])
                result.formUnion(byGuideWord[token] ?? [])
            }
            let prefix = SportsChannelPicks.compositeKey(competitionKey: competitionKey, channelKey: "")
            for key in pickIndex.keys where key.hasPrefix(prefix) {
                result.formUnion(byPickKey[String(key.dropFirst(prefix.count))] ?? [])
            }
            return result.sorted()
        }
    }

    // MARK: - Per-fixture matching

    /// What a fixture is recognised by in the guide and in channel names.
    private enum MatchTarget {
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

    private static func target(for fixture: SportsFixture) -> MatchTarget? {
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
    private struct EPGHit {
        let score: Int
        let inOneField: Bool
        /// Both teams were found only in the description — a conference.
        let descriptionOnly: Bool
        let title: String
        let start: Date
    }

    private static func resolveOne(
        fixture: SportsFixture,
        channels: [Channel],
        guide: [String: [NormalizedCandidate]],
        index: CandidateIndex
    ) -> [ResolvedChannel] {
        // With nothing to match by (a half-known pairing, a nameless event) the
        // fixture still offers the channels pinned for its competition.
        let target = target(for: fixture)
        let context = FixtureMatchContext(
            competitionKey: fixture.leagueId,
            target: target,
            kickoff: fixture.startDate
        )

        var resolved: [ResolvedChannel] = []
        let candidates = index.candidates(
            seedTokens: target?.seedTokens ?? [], competitionKey: context.competitionKey
        )
        for offset in candidates {
            if let match = matchChannel(channels[offset], context: context, guide: guide, pickIndex: index.pickIndex) {
                resolved.append(match)
            }
        }

        resolved.sort { lhs, rhs in
            if lhs.source.rank != rhs.source.rank { return lhs.source.rank < rhs.source.rank }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return gap(lhs, context.kickoff) < gap(rhs, context.kickoff)
        }

        // Confident only when a single channel holds the strongest tier alone.
        if let bestRank = resolved.first?.source.rank {
            let atBest = resolved.prefix { $0.source.rank == bestRank }.count
            if atBest == 1 { resolved[0].isConfident = true }
        }
        return resolved
    }

    /// What a channel is scored against, bundled for the parameter-count limit.
    private struct FixtureMatchContext {
        let competitionKey: String
        let target: MatchTarget?
        let kickoff: Date
    }

    /// Scores one channel against a fixture, returning the resolved channel or
    /// `nil` when it carries neither a user pick, an EPG hit, nor a name match.
    private static func matchChannel(
        _ channel: Channel,
        context: FixtureMatchContext,
        guide: [String: [NormalizedCandidate]],
        pickIndex: [String: String]
    ) -> ResolvedChannel? {
        let isPick = pickIndex[
            SportsChannelPicks.compositeKey(competitionKey: context.competitionKey, channelKey: channel.pickKey)
        ] != nil

        var epg: EPGHit?
        var nameMatched = false
        if let target = context.target {
            epg = channel.summary.epgChannelId
                .flatMap { guide[$0] }
                .flatMap { bestEPGHit(in: $0, target: target, kickoff: context.kickoff) }
            nameMatched = isPresent(target, in: channel.nameHaystack)
        }

        let source: ResolvedChannelSource
        let score: Int
        if isPick {
            source = .userPick
            score = pickScoreBase + (epg?.score ?? 0)
        } else if let epg {
            source = epg.descriptionOnly ? .epgDescription : (epg.inOneField ? .epgTitleSubtitle : .epgSingleField)
            score = epg.score
        } else if nameMatched {
            source = .channelName
            score = nameMatchScore
        } else {
            return nil
        }

        return ResolvedChannel(
            stream: channel.summary,
            playlistID: channel.playlistID,
            matchedTitle: epg?.title,
            matchedStart: epg?.start,
            score: score,
            source: source,
            isConfident: false
        )
    }

    private static func isPresent(_ target: MatchTarget, in haystack: String) -> Bool {
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
    private static func bestEPGHit(
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

    private static func teamsHit(_ candidate: NormalizedCandidate, home: Set<String>, away: Set<String>) -> EPGHit? {
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
    private static func eventHit(_ candidate: NormalizedCandidate, tokens: Set<String>) -> EPGHit? {
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

    private static func isBetterHit(_ lhs: EPGHit, than rhs: EPGHit?, kickoff: Date) -> Bool {
        guard let rhs else { return true }
        if lhs.descriptionOnly != rhs.descriptionOnly { return !lhs.descriptionOnly }
        if lhs.inOneField != rhs.inOneField { return lhs.inOneField }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return abs(lhs.start.timeIntervalSince(kickoff)) < abs(rhs.start.timeIntervalSince(kickoff))
    }

    private static func gap(_ channel: ResolvedChannel, _ kickoff: Date) -> TimeInterval {
        guard let start = channel.matchedStart else { return .greatestFiniteMagnitude }
        return abs(start.timeIntervalSince(kickoff))
    }

    /// A team is present when any distinctive token appears as a whole word.
    /// `haystack` must already be `SportsMatcher.normalize`d (space-padded).
    private static func teamPresent(_ tokens: Set<String>, in haystack: String) -> Bool {
        tokens.contains { SportsMatcher.containsWord($0, in: haystack) }
    }

    private static func allPresent(_ tokens: Set<String>, in haystack: String) -> Bool {
        tokens.allSatisfy { SportsMatcher.containsWord($0, in: haystack) }
    }

    // A sub-title hit is the fixture line itself, so it weighs more than a
    // title hit, which weighs more than a description-only (conference) hit;
    // a user pick outscores any EPG match, and a channel-name-only hit is the
    // weakest positive signal.
    private static let subtitleWeight = 3
    private static let titleWeight = 2
    private static let descriptionWeight = 1
    private static let pickScoreBase = 1000
    private static let nameMatchScore = 1
}

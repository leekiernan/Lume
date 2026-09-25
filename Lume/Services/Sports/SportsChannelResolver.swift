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
    /// An umbrella programme for the whole tour, on air at the start, that
    /// names no match ("Live ATP & WTA: Die Topspiele des Tages"). It may or
    /// may not show this one, so it is offered but never one-tap.
    case epgCompetition

    var rank: Int {
        switch self {
        case .userPick: 0
        case .epgTitleSubtitle: 1
        case .epgSingleField: 2
        case .epgDescription: 3
        case .channelName: 4
        case .epgCompetition: 5
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
    struct Channel {
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
    struct NormalizedCandidate {
        let title: String
        let normalizedTitle: String
        let normalizedSubtitle: String
        let normalizedDescription: String
        let start: Date
        let end: Date
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
                start: listing.start,
                end: listing.end
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

    private static func resolveOne(
        fixture: SportsFixture,
        channels: [Channel],
        guide: [String: [NormalizedCandidate]],
        index: CandidateIndex
    ) -> [ResolvedChannel] {
        // A race session has no two teams; it matches on series and session.
        if !fixture.hasTeams, !SportsRaceMatcher.seriesPhrases(leagueId: fixture.leagueId).isEmpty {
            let race = resolveRace(fixture: fixture, channels: channels, guide: guide, pickIndex: index.pickIndex)
            return ranked(race, kickoff: fixture.startDate)
        }
        // With nothing to match by (a half-known pairing, a nameless event) the
        // fixture still offers the channels pinned for its competition.
        let target = target(for: fixture)
        let context = FixtureMatchContext(
            competitionKey: fixture.leagueId,
            target: target,
            kickoff: fixture.startDate,
            fixture: fixture
        )

        var resolved: [ResolvedChannel] = []
        // A tour-wide umbrella block names the competition, not the players, so
        // a league with one can't be narrowed by the fixture's own tokens.
        let candidates = SportsCompetitionMatcher.phrases(leagueId: fixture.leagueId).isEmpty
            ? index.candidates(seedTokens: target?.seedTokens ?? [], competitionKey: context.competitionKey)
            : Array(channels.indices)
        for offset in candidates {
            if let match = matchChannel(channels[offset], context: context, guide: guide, pickIndex: index.pickIndex) {
                resolved.append(match)
            }
        }

        return ranked(resolved, kickoff: context.kickoff)
    }

    /// Orders channels by tier, then score, then proximity to kickoff, and marks
    /// the leader confident only when it holds the strongest tier alone.
    private static func ranked(_ channels: [ResolvedChannel], kickoff: Date) -> [ResolvedChannel] {
        var resolved = channels.sorted { lhs, rhs in
            if lhs.source.rank != rhs.source.rank { return lhs.source.rank < rhs.source.rank }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return gap(lhs, kickoff) < gap(rhs, kickoff)
        }
        if let best = resolved.first, best.source != .epgCompetition {
            let bestRank = best.source.rank
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
        let fixture: SportsFixture
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
        } else if let umbrella = channel.summary.epgChannelId
            .flatMap({ guide[$0] })
            .flatMap({ competitionHit(in: $0, fixture: context.fixture) })
        {
            return ResolvedChannel(
                stream: channel.summary,
                playlistID: channel.playlistID,
                matchedTitle: umbrella.title,
                matchedStart: umbrella.start,
                score: umbrella.score,
                source: .epgCompetition,
                isConfident: false
            )
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

    private static func gap(_ channel: ResolvedChannel, _ kickoff: Date) -> TimeInterval {
        guard let start = channel.matchedStart else { return .greatestFiniteMagnitude }
        return abs(start.timeIntervalSince(kickoff))
    }

    // A sub-title hit is the fixture line itself, so it weighs more than a
    // title hit, which weighs more than a description-only (conference) hit;
    // a user pick outscores any EPG match, and a channel-name-only hit is the
    // weakest positive signal.
    static let subtitleWeight = 3
    static let titleWeight = 2
    static let descriptionWeight = 1
    static let pickScoreBase = 1000
    static let nameMatchScore = 1
}

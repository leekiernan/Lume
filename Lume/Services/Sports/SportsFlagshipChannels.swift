//
//  SportsFlagshipChannels.swift
//  Lume
//
//  A broadcaster puts its biggest game on its flagship channel — Sky Sports
//  Main Event, TNT Sports 1, BBC One — and the rest on secondary ones. So a
//  game listed on a flagship in the viewer's own guide is a big game by the
//  broadcaster's own judgement, for the viewer's own region: the strongest
//  "Big this week" signal there is, and nearly free.
//
//  Flagship is a property of the channel, not the game: the viewer's channels
//  are classified once by name (recomputed only when a playlist or guide
//  syncs), then only those few channels' guides are read for the week's games.
//  The built-in names lean UK and Europe; the viewer can mark any channel as a
//  main channel from its menu, or unmark one.
//

import Foundation
import SwiftData
import Synchronization

nonisolated enum SportsFlagshipChannels {
    /// Normalised name phrases that identify a flagship, matched as whole words
    /// after any "UK:" / "DE |" prefix and quality tag are ignored.
    static let phrases: [String] = [
        // UK & Ireland
        "sky sports main event", "sky sports premier league", "sky sports f1", "tnt sports 1", "bbc one", "bbc 1",
        "itv1", "itv 1", "channel 4", "premier sports 1", "rte2", "rte 2",
        // Germany / Austria
        "sky sport top event", "sky sport bundesliga 1", "sky sport 1", "dazn 1", "sport1", "das erste", "zdf",
        // Spain / Italy / France / Portugal / Netherlands
        "movistar laliga", "m laliga", "dazn laliga", "sky sport uno", "sky sport calcio", "rai 1", "canal sport",
        "canal plus sport", "bein sports 1", "tf1", "sport tv1", "sport tv 1", "espn 1", "ziggo sport",
        // North America
        "espn", "tsn1", "sportsnet one"
    ]

    /// Whether a channel name names a flagship, given the viewer's own marks.
    static func isFlagship(_ name: String, overrides: SportsFlagshipOverrides.Marks) -> Bool {
        let key = SportsFlagshipOverrides.key(for: name)
        if overrides.unmarked.contains(key) { return false }
        if overrides.marked.contains(key) { return true }
        // A pay-per-view channel carries only events someone will pay for.
        if SportsPayPerView.isPayPerView(name) { return true }
        let haystack = SportsMatcher.normalize(name)
        return phrases.contains { haystack.contains(" \($0) ") }
    }

    // MARK: - Finding games on flagships

    private static let cache = Mutex<(generation: SportsChannelResolver.CacheGeneration, channels: [Flagship])?>(nil)
    private static let results = Mutex<FlagshipResultCache?>(nil)
    /// Short enough to heal an EPG edit that did not advance a source timestamp,
    /// long enough that switching between Sports surfaces does not re-read the
    /// same flagship listings.
    private static let resultLifetime: TimeInterval = 10 * 60

    struct Flagship: Equatable {
        let name: String
        let epgChannelId: String
    }

    private struct FlagshipResultCache {
        let key: ResultKey
        let values: [String: String]
        let createdAt: Date
    }

    private struct ResultKey: Hashable {
        let generation: SportsChannelResolver.CacheGeneration
        /// Fixture identity includes kickoff because a reschedule changes its
        /// guide window without necessarily changing the provider id.
        let fixtures: [String]
    }

    /// For each fixture that one of the viewer's flagship channels lists around
    /// its kickoff, that channel's name.
    static func mainChannels(
        for fixtures: [SportsFixture],
        container: ModelContainer,
        restriction: ContentRestriction,
        overrides: SportsFlagshipOverrides.Marks,
        now: Date
    ) async -> [String: String] {
        guard !fixtures.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            let generation = SportsChannelResolver.CacheGeneration(
                container: container, context: context, restriction: restriction, picks: overrides.cacheKey
            )
            let key = ResultKey(
                generation: generation,
                fixtures: fixtures.map(SportsChannelResolver.ResolveCache.key).sorted()
            )
            if let cached = results.withLock({ $0 }), cached.key == key,
               now.timeIntervalSince(cached.createdAt) < resultLifetime
            {
                return cached.values
            }

            let flagships = flagshipChannels(context: context, generation: generation, restriction: restriction, overrides: overrides)
            guard !flagships.isEmpty else {
                results.withLock { $0 = FlagshipResultCache(key: key, values: [:], createdAt: now) }
                return [:]
            }
            let byEPG = Dictionary(flagships.map { ($0.epgChannelId, $0.name) }, uniquingKeysWith: { first, _ in first })
            // Do not turn several kickoff windows into one multi-hour guide
            // scan. Adjacent/overlapping windows still merge in the resolver,
            // while sparse fixtures read only the programme rows that can match.
            var seen: Set<PersistentIdentifier> = []
            let listings = SportsChannelResolver.guideWindows(for: fixtures).flatMap { window in
                ((try? context.fetch(SportsChannelResolver.epgCandidateDescriptor(
                    channelIds: Array(byEPG.keys), windowStart: window.lowerBound, windowEnd: window.upperBound
                ))) ?? []).filter { seen.insert($0.persistentModelID).inserted }
            }
            let lines = listings.map { listing in
                (channel: listing.channelId, start: listing.start,
                 text: SportsMatcher.normalize("\(listing.title) \(listing.subtitle ?? "")"))
            }
            var found: [String: String] = [:]
            for fixture in fixtures {
                guard let target = SportsChannelResolver.target(for: fixture) else { continue }
                let windowStart = fixture.headlineDate.addingTimeInterval(-SportsMatcher.leadTime)
                let windowEnd = fixture.headlineDate.addingTimeInterval(SportsMatcher.lateStart)
                if let hit = lines.first(where: { $0.start >= windowStart && $0.start <= windowEnd && SportsChannelResolver.isPresent(target, in: $0.text) }),
                   let name = byEPG[hit.channel]
                {
                    found[fixture.id] = name
                }
            }
            results.withLock { $0 = FlagshipResultCache(key: key, values: found, createdAt: now) }
            return found
        }.value
    }

    /// The viewer's flagship channels with a guide id, worked out once per
    /// catalog generation (a playlist or guide sync starts a new one).
    private static func flagshipChannels(
        context: ModelContext,
        generation: SportsChannelResolver.CacheGeneration,
        restriction: ContentRestriction,
        overrides: SportsFlagshipOverrides.Marks
    ) -> [Flagship] {
        if let cached = cache.withLock({ $0 }), cached.generation == generation {
            return cached.channels
        }
        let streams = (try? context.fetch(SportsChannelResolver.candidateStreamDescriptor(restriction: restriction))) ?? []
        var seen: Set<String> = []
        let channels = streams.compactMap { stream -> Flagship? in
            guard let epg = stream.epgChannelId, !epg.isEmpty,
                  isFlagship(stream.name, overrides: overrides),
                  seen.insert(epg).inserted
            else { return nil }
            return Flagship(name: stream.name, epgChannelId: epg)
        }
        cache.withLock { $0 = (generation, channels) }
        return channels
    }
}

/// The viewer's own corrections: channels marked as a main channel, or a
/// built-in one unmarked. Device-local, like remembered channel picks — it
/// describes this device's playlists.
@MainActor
@Observable
final class SportsFlagshipOverrides {
    static let shared = SportsFlagshipOverrides()
    static let defaultsKey = "sports.flagshipOverrides.v1"

    nonisolated struct Marks: Codable, Equatable {
        var marked: Set<String> = []
        var unmarked: Set<String> = []

        /// Folded into the flagship cache key, so a change re-classifies.
        var cacheKey: [String: String] {
            Dictionary(uniqueKeysWithValues: marked.map { ($0, "+") } + unmarked.map { ($0, "-") })
        }
    }

    private let defaults: UserDefaults
    private(set) var marks: Marks

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        marks = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Marks.self, from: $0) } ?? Marks()
    }

    /// A channel's identity across playlists: its name, normalised.
    nonisolated static func key(for name: String) -> String {
        SportsMatcher.normalize(name).trimmingCharacters(in: .whitespaces)
    }

    func isFlagship(_ name: String) -> Bool {
        SportsFlagshipChannels.isFlagship(name, overrides: marks)
    }

    func toggle(_ name: String) {
        let key = Self.key(for: name)
        let builtIn = SportsFlagshipChannels.isFlagship(name, overrides: Marks())
        if isFlagship(name) {
            marks.marked.remove(key)
            if builtIn { marks.unmarked.insert(key) }
        } else {
            marks.unmarked.remove(key)
            if !builtIn { marks.marked.insert(key) }
        }
        defaults.set(try? JSONEncoder().encode(marks), forKey: Self.defaultsKey)
    }
}

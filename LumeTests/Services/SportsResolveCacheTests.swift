//
//  SportsResolveCacheTests.swift
//  LumeTests
//
//  The resolver reuses an answer while the catalog, guide and viewer behind it
//  are unchanged, and recomputes once any of them moves.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

/// `ResolveCache.shared` holds one generation: a resolve from any other suite
/// resets it, so these run alone (the other resolver suites take the lock shared).
@MainActor
@Suite(.globalState)
struct SportsResolveCacheTests {
    init() {
        SportsChannelResolver.ResolveCache.shared.removeAll()
    }

    private let leagueId = "espn:soccer/ger.1"

    private func makeContainer() throws -> ModelContainer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: OnDiskCatalogStore.catalogSchema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: OnDiskCatalogStore.catalogSchema, configurations: [config])
    }

    private func fixture(kickoff: Date) -> SportsFixture {
        SportsFixture(
            id: "evt-cache",
            leagueId: leagueId,
            leagueName: "Bundesliga",
            leagueAbbreviation: "BUND",
            startDate: kickoff,
            status: SportsFixtureStatus(state: .scheduled),
            home: SportsCompetitor(team: SportsTeam(leagueId: leagueId, teamId: "1", name: "Bayern", shortName: "Bayern", abbreviation: "")),
            away: SportsCompetitor(team: SportsTeam(leagueId: leagueId, teamId: "2", name: "Dortmund", shortName: "Dortmund", abbreviation: ""))
        )
    }

    @Test func `a fight card cache key follows its main card`() {
        let earlyPrelims = Date(timeIntervalSince1970: 1_800_000_000)
        let first = SportsFixture(
            id: "ufc", leagueId: leagueId, leagueName: "UFC", leagueAbbreviation: "UFC",
            startDate: earlyPrelims, status: SportsFixtureStatus(state: .scheduled),
            mainCardDate: earlyPrelims.addingTimeInterval(3 * 3600)
        )
        let rescheduled = SportsFixture(
            id: "ufc", leagueId: leagueId, leagueName: "UFC", leagueAbbreviation: "UFC",
            startDate: earlyPrelims, status: SportsFixtureStatus(state: .scheduled),
            mainCardDate: earlyPrelims.addingTimeInterval(4 * 3600)
        )

        #expect(SportsChannelResolver.ResolveCache.key(for: first) != SportsChannelResolver.ResolveCache.key(for: rescheduled))
    }

    @Test func `an unchanged catalog reuses the answer, a sync recomputes it`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "P", serverURL: "http://p.test", username: "u", password: "p")
        context.insert(playlist)
        let prefix = playlist.id.uuidString
        context.insert(LiveStream(id: "\(prefix)-live-1", streamId: 1, name: "Sky Bundesliga", epgChannelId: "sky.de"))
        let kickoff = Date()
        let listing = EPGListing(
            id: "sky.de-1", channelId: "sky.de", title: "Bundesliga", listingDescription: "",
            start: kickoff, end: kickoff.addingTimeInterval(7200), subtitle: "Bayern vs Dortmund", category: "Sport"
        )
        context.insert(listing)
        try context.save()
        let game = fixture(kickoff: kickoff)

        let first = await SportsChannelResolver.resolve(container: container, fixtures: [game])
        #expect(first[game.id]?.count == 1)

        // The guide changes in place: same row count, no sync recorded.
        listing.subtitle = "Something Else"
        try context.save()
        let cached = await SportsChannelResolver.resolve(container: container, fixtures: [game])
        #expect(cached[game.id]?.count == 1)

        // A finished sync moves the generation, so the answer is recomputed.
        playlist.lastSyncDate = Date()
        try context.save()
        let recomputed = await SportsChannelResolver.resolve(container: container, fixtures: [game])
        #expect(recomputed[game.id]?.isEmpty == true)
    }

    @Test func `hiding a channel recomputes the answer`() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let stream = LiveStream(id: "\(UUID().uuidString)-live-1", streamId: 1, name: "Sky Bundesliga", epgChannelId: "sky.de")
        context.insert(stream)
        let kickoff = Date()
        context.insert(EPGListing(
            id: "sky.de-1", channelId: "sky.de", title: "Bundesliga", listingDescription: "",
            start: kickoff, end: kickoff.addingTimeInterval(7200), subtitle: "Bayern vs Dortmund", category: "Sport"
        ))
        try context.save()
        let game = fixture(kickoff: kickoff)

        #expect(await SportsChannelResolver.resolve(container: container, fixtures: [game])[game.id]?.count == 1)

        stream.isHidden = true
        try context.save()

        // With no visible channel left, the resolver has no entry for the game.
        let afterHiding = await SportsChannelResolver.resolve(container: container, fixtures: [game])
        #expect((afterHiding[game.id] ?? []).isEmpty)
    }

    @Test func `unchanged guide checks retain cache generation but published snapshots invalidate it`() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let source = EPGSource(name: "Guide", url: "https://example.com/guide.xml")
        source.committedGeneration = 1
        context.insert(source)
        try context.save()
        let first = SportsChannelResolver.CacheGeneration(container: container, context: context, restriction: ContentRestriction(), picks: [:])
        source.lastSyncDate = Date()
        try context.save()
        let unchanged = SportsChannelResolver.CacheGeneration(container: container, context: context, restriction: ContentRestriction(), picks: [:])
        #expect(first == unchanged)
        source.committedGeneration += 1
        try context.save()
        let published = SportsChannelResolver.CacheGeneration(container: container, context: context, restriction: ContentRestriction(), picks: [:])
        #expect(first != published)
    }
}

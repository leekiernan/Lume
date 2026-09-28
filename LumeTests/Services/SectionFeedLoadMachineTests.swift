//
//  SectionFeedLoadMachineTests.swift
//  LumeTests
//
//  The section feed's load lifecycle: per-source transitions, settling, and
//  the scope change that must reload every source it resets.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SectionFeedLoadMachineTests {
    @Test func `a load shows as loading or cached until it finishes`() {
        var machine = SectionFeedLoadMachine()
        _ = machine.handle(.began(.trending, key: "a", cache: .missing))
        _ = machine.handle(.began(.custom, key: "a", cache: .stale))
        #expect(machine.state(of: .trending) == .loading)
        #expect(machine.state(of: .custom) == .cached)

        _ = machine.handle(.finished(.trending, .loaded))
        _ = machine.handle(.finished(.custom, .failed))
        #expect(machine.state(of: .trending) == .loaded)
        #expect(machine.state(of: .custom) == .failed)
    }

    @Test func `a load that never began cannot finish`() {
        var machine = SectionFeedLoadMachine()
        let finish = SectionFeedLoadMachine.Event.finished(.watchlist(.simkl), .loaded)
        #expect(!SectionFeedLoadMachine.isValid(finish, in: machine.state(of: .watchlist(.simkl))))
        _ = machine.handle(finish)
        #expect(machine.state(of: .watchlist(.simkl)) == .idle)
    }

    @Test func `the surface is settled only once every source is`() {
        var machine = SectionFeedLoadMachine()
        for source in SectionFeedSource.allCases.dropLast() {
            _ = machine.handle(.began(source, key: "k", cache: .missing))
            _ = machine.handle(.finished(source, .loaded))
        }
        #expect(!machine.isSettled)
        _ = machine.handle(.began(.custom, key: "k", cache: .missing))
        _ = machine.handle(.finished(.custom, .failed))
        #expect(machine.isSettled)
    }

    @Test func `the first scope and an unchanged scope need nothing`() {
        var machine = SectionFeedLoadMachine()
        #expect(machine.handle(.contextChanged(identity: "a")).isEmpty)
        _ = machine.handle(.began(.trending, key: "k", cache: .missing))
        #expect(machine.handle(.contextChanged(identity: "a")).isEmpty)
        #expect(machine.state(of: .trending) == .loading)
    }

    @Test func `a scope change resets every source and reloads each one asked for`() {
        var machine = SectionFeedLoadMachine()
        _ = machine.handle(.contextChanged(identity: "playlist-a"))
        _ = machine.handle(.began(.trending, key: "t1", cache: .missing))
        _ = machine.handle(.finished(.trending, .loaded))
        _ = machine.handle(.began(.watchlist(.trakt), key: "w1", cache: .fresh))

        let effects = machine.handle(.contextChanged(identity: "playlist-b"))

        #expect(effects == [
            .discardCatalogModels,
            .reload(.trending, key: "t1"),
            .reload(.watchlist(.trakt), key: "w1")
        ])
        #expect(SectionFeedSource.allCases.allSatisfy { machine.state(of: $0) == .idle })
        #expect(machine.contextIdentity == "playlist-b")
    }

    @Test func `row failures are tracked per row and cleared by a scope change`() {
        var machine = SectionFeedLoadMachine()
        let alpha = HomeSectionRef.custom(UUID())
        let beta = HomeSectionRef.custom(UUID())
        _ = machine.handle(.contextChanged(identity: "a"))
        _ = machine.handle(.rowsFailed([alpha, beta]))
        _ = machine.handle(.rowsRecovered([beta]))
        #expect(machine.failedRows == [alpha])

        _ = machine.handle(.contextChanged(identity: "b"))
        #expect(machine.failedRows.isEmpty)
    }

    @Test func `hero state follows its source until it settles`() {
        var machine = SectionFeedLoadMachine()
        let hero = HomeSectionRef.builtin(.trendingMovies)
        #expect(machine.heroState(for: nil, hasSlides: false, rowHasItems: false) == .disabled)
        #expect(machine.heroState(for: hero, hasSlides: false, rowHasItems: false) == .loading)

        _ = machine.handle(.began(.trending, key: "k", cache: .stale))
        #expect(machine.heroState(for: hero, hasSlides: false, rowHasItems: true) == .loading)
        #expect(machine.heroState(for: hero, hasSlides: true, rowHasItems: true) == .content)

        _ = machine.handle(.finished(.trending, .loaded))
        // Resolved to nothing: empty. Resolved titles but no wide art: failed.
        #expect(machine.heroState(for: hero, hasSlides: false, rowHasItems: false) == .empty)
        #expect(machine.heroState(for: hero, hasSlides: false, rowHasItems: true) == .failed)

        _ = machine.handle(.rowsFailed([hero]))
        #expect(machine.heroState(for: hero, hasSlides: false, rowHasItems: false) == .failed)
    }

    @Test func `a hero whose source failed is failed`() {
        var machine = SectionFeedLoadMachine()
        let hero = HomeSectionRef.builtin(.traktWatchlist)
        _ = machine.handle(.began(.watchlist(.trakt), key: "k", cache: .missing))
        _ = machine.handle(.finished(.watchlist(.trakt), .failed))
        #expect(machine.heroState(for: hero, hasSlides: false, rowHasItems: false) == .failed)
    }

    @Test func `rows map to the feed that loads them`() {
        #expect(SectionFeedSource(row: .builtin(.trendingSeries)) == .trending)
        #expect(SectionFeedSource(row: .builtin(.simklWatchlist)) == .watchlist(.simkl))
        #expect(SectionFeedSource(row: .custom(UUID())) == .custom)
        #expect(SectionFeedSource(row: .builtin(.recentlyWatched)) == nil)
    }

    /// The gap the machine closes: a scope change wipes every row, and a source
    /// whose view task doesn't re-run must still come back rather than stay
    /// empty for the session.
    @Test func `a feed reloads a source its view never asks for again`() async throws {
        let schema = Schema([Movie.self, Series.self, Episode.self, LiveStream.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let feed = SectionFeed(surface: .home)
        func context(_ prefix: String) -> SectionFeed.Context {
            SectionFeed.Context(modelContext: container.mainContext, restriction: ContentRestriction(), playlistPrefix: prefix)
        }

        feed.update(context: context("a-"))
        await feed.loadCustomSections(cacheKey: "custom", sections: [])
        #expect(feed.loads.state(of: .custom) == .loaded)

        feed.update(context: context("b-"))
        #expect(feed.loads.state(of: .custom) == .idle)

        for _ in 0 ..< 50 where feed.loads.state(of: .custom) != .loaded {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(feed.loads.state(of: .custom) == .loaded)
    }
}

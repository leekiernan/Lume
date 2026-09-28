//
//  SectionSurfaceDisplayTests.swift
//  LumeTests
//
//  What a section surface decides to show from what it knows.
//

@testable import Lume
import Testing

@MainActor
struct SectionSurfaceDisplayTests {
    private func snapshot(
        hasPlaylists: Bool = true,
        local: [String: Int] = [:],
        feed: [String: Int] = [:],
        other: Bool = false,
        settled: Bool = true,
        hero: HeroLoadState = .disabled
    ) -> SectionSurfaceSnapshot {
        SectionSurfaceSnapshot(
            hasPlaylists: hasPlaylists, localRows: local, feedRows: feed,
            hasOtherContent: other, feedSettled: settled, hero: hero
        )
    }

    @Test func `no playlists wins over everything`() {
        #expect(snapshot(hasPlaylists: false, local: ["favorites": 3]).display == .noPlaylists)
    }

    @Test func `empty only once the feed has settled`() {
        #expect(snapshot(settled: true).display == .empty)
        #expect(snapshot(settled: false, hero: .loading).display == .content(hero: .loading))
    }

    @Test func `any row or other content shows the surface`() {
        #expect(snapshot(local: ["recentlyWatched": 3], feed: ["trendingMovies": 0]).display == .content(hero: .disabled))
        #expect(snapshot(feed: ["trendingMovies": 20], hero: .content).display == .content(hero: .content))
        #expect(snapshot(other: true).display == .content(hero: .disabled))
    }

    @Test func `the journal line carries every count behind the decision`() {
        let line = snapshot(
            local: ["recentlyWatched": 3],
            feed: ["trendingMovies": 0, "trendingSeries": 0],
            hero: .empty
        ).logDescription
        #expect(line.contains("recentlyWatched 3"))
        #expect(line.contains("trendingMovies 0, trendingSeries 0"))
        #expect(line.contains("feed settled: true"))
    }
}

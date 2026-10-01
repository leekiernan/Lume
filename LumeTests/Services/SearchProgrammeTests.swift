//
//  SearchProgrammeTests.swift
//  LumeTests
//
//  Search finds guide programmes: on now or still to come — never already
//  aired — each on a channel the viewer can see, soonest first. And it offers,
//  searches and names only the areas switched on.
//
//  Against an on-disk SQLite store, like `SearchPredicateTests`: in-memory
//  stores evaluate predicates without generating SQL.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SearchProgrammeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSQLiteContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func listing(_ id: String, channel: String, title: String, from start: TimeInterval, to end: TimeInterval) -> EPGListing {
        EPGListing(
            id: id, channelId: channel, title: title, listingDescription: "",
            start: now.addingTimeInterval(start), end: now.addingTimeInterval(end)
        )
    }

    /// One channel on air, one hidden, one restricted; a programme that
    /// aired, one on now and two to come.
    private func seed(_ container: ModelContainer) throws {
        let context = container.mainContext
        let visible = LiveStream(id: "p-live-1", streamId: 1, name: "Sports One", epgChannelId: "sport.one")
        let hidden = LiveStream(id: "p-live-2", streamId: 2, name: "Hidden", epgChannelId: "hidden.one")
        hidden.isHidden = true
        let restricted = LiveStream(id: "p-live-3", streamId: 3, name: "Late", epgChannelId: "late.one", categoryId: "adult")
        [visible, hidden, restricted].forEach(context.insert)
        [
            listing("aired", channel: "sport.one", title: "Match of the Day", from: -7200, to: -3600),
            listing("now", channel: "sport.one", title: "Match of the Day", from: -600, to: 1800),
            listing("later", channel: "sport.one", title: "Match of the Day Live", from: 7200, to: 9000),
            listing("soon", channel: "sport.one", title: "Match Preview", from: 1800, to: 3600),
            listing("hidden", channel: "hidden.one", title: "Match Hidden", from: 600, to: 1200),
            listing("restricted", channel: "late.one", title: "Match Late", from: 600, to: 1200)
        ].forEach(context.insert)
        try context.save()
    }

    private func search(_ container: ModelContainer, _ query: String, excluded: Set<String> = []) -> SearchHits {
        SearchFetcher.fetch(container: container, request: SearchRequest(
            query: query, playlistIDs: [], wantMovies: false, wantSeries: false, wantLive: true,
            excludedCategoryIDs: excluded, limit: 50, now: now
        ))
    }

    @Test func `programmes on now and to come are found, never ones already aired`() throws {
        let container = try makeSQLiteContainer()
        try seed(container)

        let hits = search(container, "match", excluded: ["adult"])
        let titles = hits.programmes.map(\.slot.title)

        #expect(titles == ["Match of the Day", "Match Preview", "Match of the Day Live"])
        #expect(hits.programmes.map(\.isCurrent) == [true, false, false])
    }

    @Test func `a hidden channel's or restricted category's programmes stay out`() throws {
        let container = try makeSQLiteContainer()
        try seed(container)

        let titles = search(container, "match", excluded: ["adult"]).programmes.map(\.slot.title)

        #expect(!titles.contains("Match Hidden"))
        #expect(!titles.contains("Match Late"))
    }

    @Test func `no live search, no programmes`() throws {
        let container = try makeSQLiteContainer()
        try seed(container)

        let hits = SearchFetcher.fetch(container: container, request: SearchRequest(
            query: "match", playlistIDs: [], wantMovies: true, wantSeries: true, wantLive: false,
            excludedCategoryIDs: [], limit: 50, now: now
        ))
        #expect(hits.programmes.isEmpty)
    }

    // MARK: - Areas

    @Test func `filters offer only the areas switched on`() {
        #expect(ContentFilter.available(disabledRaw: "") == [.all, .movies, .series, .liveTV])
        #expect(ContentFilter.available(disabledRaw: "series") == [.all, .movies, .liveTV])
        // One area left: nothing to narrow, so no filter at all.
        #expect(ContentFilter.available(disabledRaw: "movies,series").isEmpty)
    }

    @Test func `the hint names only the areas switched on`() {
        let all = SearchPrompt.description(for: [.movies, .series, .liveTV])
        let noSeries = SearchPrompt.description(for: [.movies, .liveTV])

        #expect(all == String(localized: "Search for movies, series, or live TV channels"))
        #expect(!noSeries.contains(String(localized: "series", comment: "")))
        #expect(SearchPrompt.field(for: [.movies, .liveTV]) == "\(String(localized: "Movies")), \(String(localized: "Live TV"))…")
    }
}

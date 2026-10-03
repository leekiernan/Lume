import Foundation
@testable import Lume
import SwiftData
import Testing

/// The series watch grids page through one watched-series query and split it
/// afterwards. A page wholly on the other side of the split mustn't end the
/// walk with an empty grid (`SeriesWatchSplit.settle`).
@MainActor
struct SeriesWatchSplitPagingTests {
    private let prefix = "p"
    private let pageSize = 2

    /// `finished` series have their only episode watched; the rest have it
    /// unwatched, which leaves them in progress. Listed most recent first.
    private func seed(_ finished: [Bool], in context: ModelContext) throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, isFinished) in finished.enumerated() {
            let series = Series(id: "\(prefix)-series-\(index)", seriesId: index, name: "Show \(index)")
            series.lastWatchedDate = start.addingTimeInterval(-Double(index) * 60)
            context.insert(series)
            let episode = Episode(
                id: "\(prefix)-series-\(index)-e1", episodeId: "\(index)", title: "E1",
                containerExtension: "mkv", seasonNum: 1, episodeNum: 1, series: series
            )
            episode.isWatched = isFinished
            context.insert(episode)
        }
        try context.save()
    }

    private func settle(
        _ kind: LibraryCollection.Kind,
        collection: PagedCollection<Series>,
        in context: ModelContext
    ) async -> ContinueWatchingLoader.Result? {
        let container = context.container
        func loadNextPage() {
            collection.loadNextPage(in: context, pageSize: pageSize) { offset, limit in
                SeriesCollectionQuery.pageDescriptor(
                    for: kind, playlistPrefix: prefix, excludedCategoryIDs: [], offset: offset, limit: limit
                )
            }
        }
        collection.prepare(for: kind.rawValue)
        loadNextPage()
        return await SeriesWatchSplit.settle(
            kind,
            collection: collection,
            progress: { series in ContinueWatchingLoader.load(container: container, series: series.map(\.persistentModelID)) },
            loadNextPage: loadNextPage
        )
    }

    @Test func `watch Again reaches finished shows behind a page of unfinished ones`() async throws {
        let context = try ModelContext(makeTestContainer())
        try seed([false, false, false, true, true], in: context)
        let collection = PagedCollection<Series>()

        let progress = try #require(await settle(.recentlyWatched, collection: collection, in: context))
        let shown = SeriesWatchSplit.shown(collection.items, for: .recentlyWatched, progress: progress)
        #expect(shown.map(\.id) == ["p-series-3"])
        // Stopped at the page that showed something; the rest loads on scroll.
        #expect(collection.items.count == 4)
        #expect(collection.canLoadMore)
    }

    @Test func `continue Watching reaches unfinished shows behind finished ones`() async throws {
        let context = try ModelContext(makeTestContainer())
        try seed([true, true, true, true, false], in: context)
        let collection = PagedCollection<Series>()

        let progress = try #require(await settle(.continueWatching, collection: collection, in: context))
        let shown = SeriesWatchSplit.shown(collection.items, for: .continueWatching, progress: progress)
        #expect(shown.map(\.id) == ["p-series-4"])
    }

    @Test func `an empty split ends at the end of the source`() async throws {
        let context = try ModelContext(makeTestContainer())
        try seed([false, false, false], in: context)
        let collection = PagedCollection<Series>()

        let progress = try #require(await settle(.recentlyWatched, collection: collection, in: context))
        #expect(SeriesWatchSplit.shown(collection.items, for: .recentlyWatched, progress: progress).isEmpty)
        #expect(collection.items.count == 3)
        #expect(!collection.canLoadMore)
    }

    @Test func `a cancelled settle keeps the caller's split`() async throws {
        let context = try ModelContext(makeTestContainer())
        try seed([false, false, true], in: context)
        let collection = PagedCollection<Series>()
        collection.prepare(for: "x")

        let task = Task { @MainActor in
            await SeriesWatchSplit.settle(
                .recentlyWatched,
                collection: collection,
                progress: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return ContinueWatchingLoader.Result()
                },
                loadNextPage: {}
            )
        }
        #expect(await task.value == nil)
    }
}

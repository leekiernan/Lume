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

    @Test func `the split owns its page drain without restarting its task`() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        try seed([false, false, false, false, true], in: context)
        let collection = PagedCollection<Series>()
        collection.prepare(for: "watch")
        func loadPage() {
            collection.loadNextPage(in: context, pageSize: pageSize) { offset, limit in
                SeriesCollectionQuery.pageDescriptor(for: .recentlyWatched, playlistPrefix: prefix, excludedCategoryIDs: [], offset: offset, limit: limit)
            }
        }
        loadPage()
        func key() -> [String] {
            SeriesCatalog.progressRequestKey(request: "watch", loaded: collection.pagination.key, items: collection.items, kind: .recentlyWatched)
        }
        var machine = CollectionWatchSplitMachine()
        machine.update(for: key())
        let originalTaskKey = machine.taskKey
        let request = machine.begin()
        var passes = 0
        let result = try #require(await SeriesWatchSplit.settle(.recentlyWatched, collection: collection, progress: { items in
            passes += 1
            return ContinueWatchingLoader.load(container: container, series: items.map(\.persistentModelID))
        }, loadNextPage: {
            loadPage()
            machine.update(for: key()) // The view observes each page append.
            #expect(machine.taskKey == originalTaskKey)
        }))
        #expect(passes == 3)
        let finished = machine.finish(request, publishedKey: key())
        #expect(finished)
        machine.update(for: key()) // A deferred onChange may arrive after finish.
        #expect(machine.taskKey == originalTaskKey)
        #expect(result.finished == ["p-series-4"])
        collection.items.first?.lastWatchedDate = Date.now
        machine.update(for: key())
        #expect(machine.taskKey != originalTaskKey)
    }

    @Test func `watch edits and scope replacements invalidate an active split but appends do not`() {
        var machine = CollectionWatchSplitMachine()
        let initial = ["watch-profile", "watch-profile", "show-a|1"]
        machine.update(for: initial)
        let first = machine.begin()
        machine.update(for: initial + ["show-b|2"])
        #expect(machine.taskKey == initial)
        let edited = ["watch-profile", "watch-profile", "show-a|3", "show-b|2"]
        machine.update(for: edited)
        #expect(machine.taskKey == edited)
        let staleEdit = machine.finish(first)
        #expect(!staleEdit)
        let second = machine.begin()
        machine.update(for: ["other-profile", "other-profile", "show-a|3"])
        let replacement = machine.begin()
        let staleScope = machine.finish(second)
        let current = machine.finish(replacement)
        #expect(!staleScope)
        #expect(current)
    }
}

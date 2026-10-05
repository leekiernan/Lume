import Foundation
@testable import Lume
import SwiftData
import Testing

@Suite(.readsGlobalState)
struct ProviderImportTests {
    @Test func `library walk keeps first structural failure but visits every library`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        var visited: [Int] = []
        let failure = try await manager.walkLibraries([1, 2, 3], name: \.description) { library in
            visited.append(library)
            if library == 1 { throw ProviderImportError.incompletePage(fetched: 1, expected: 2) }
            if library == 2 { throw ProviderImportError.invalidTotal(-1) }
        }
        #expect(visited == [1, 2, 3])
        #expect(failure == .incompletePage(fetched: 1, expected: 2))
        let empty = try await manager.walkLibraries([Int](), name: \.description) { _ in Issue.record("empty walk ran") }
        #expect(empty == nil)
    }

    @Test func `transport failure stops the remaining libraries`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        var visited: [Int] = []
        await #expect(throws: URLError.self) {
            try await manager.walkLibraries([1, 2, 3], name: \.description) { library in
                visited.append(library)
                if library == 2 { throw URLError(.notConnectedToInternet) }
            }
        }
        #expect(visited == [1, 2])
    }

    @Test func `cancellation after the last library cannot grant prune authority`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        let task = Task {
            do {
                _ = try await manager.walkLibraries([1], name: \.description) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return false
            } catch is CancellationError { return true }
        }
        #expect(try await task.value)
    }

    @Test func `paging uses the number received rather than an assumed page size`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        var offsets: [Int] = []
        var imported: [Int] = []
        var progress: [Int] = []
        let count = try await manager.walkProviderPages { offset in
            offsets.append(offset)
            return ProviderImportPage(items: offset == 0 ? [1, 2] : [3], total: 3)
        } consume: { imported += $0 } report: { count, _ in progress.append(count) }
        #expect(count == 3)
        #expect(offsets == [0, 2])
        #expect(imported == [1, 2, 3])
        #expect(progress == [2, 3])
    }

    @Test func `early empty pages fail instead of granting prune authority`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        var imported: [Int] = []
        await #expect(throws: ProviderImportError.incompletePage(fetched: 1, expected: 3)) {
            try await manager.walkProviderPages { offset in
                ProviderImportPage(items: offset == 0 ? [1] : [], total: 3)
            } consume: { imported += $0 } report: { _, _ in }
        }
        #expect(imported == [1])
    }

    @Test func `a truly empty library completes without consuming a page`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        var consumed = false
        let count = try await manager.walkProviderPages { _ in
            ProviderImportPage<Int>(items: [], total: 0)
        } consume: { _ in consumed = true } report: { _, _ in }
        #expect(count == 0)
        #expect(!consumed)
    }

    @Test func `negative totals fail before a page is saved`() async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        var consumed = false
        await #expect(throws: ProviderImportError.invalidTotal(-1)) {
            try await manager.walkProviderPages { _ in
                ProviderImportPage(items: [1], total: -1)
            } consume: { _ in consumed = true } report: { _, _ in }
        }
        #expect(!consumed)
    }

    @Test(arguments: [false, true])
    func `cancellation cannot publish a response or grant final prune authority`(afterReport: Bool) async throws {
        let manager = try ContentSyncManager(modelContainer: makeTestContainer())
        // Cancel a child task, not Swift Testing's own task (which would mark
        // the regression skipped instead of checking the cancellation path).
        let task = Task {
            var consumed = false
            do {
                _ = try await manager.walkProviderPages { _ in
                    if !afterReport { withUnsafeCurrentTask { $0?.cancel() } }
                    return ProviderImportPage(items: [1], total: 1)
                } consume: { _ in consumed = true } report: { _, _ in
                    if afterReport { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return (cancelled: false, consumed: consumed)
            } catch is CancellationError {
                return (cancelled: true, consumed: consumed)
            }
        }
        let outcome = try await task.value
        #expect(outcome.cancelled)
        #expect(outcome.consumed == afterReport)
    }

    @Test func `category updates preserve user state and scope`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Categories", serverURL: "https://provider.test", username: "", password: "")
        context.insert(playlist)
        let category = Category(apiId: "1", name: "Old", parentId: 7, type: .vod, playlist: playlist)
        category.isHidden = true
        category.isRestricted = true
        category.customOrder = 4
        category.customIcon = "star"
        category.contentImportedAt = Date(timeIntervalSince1970: 100)
        context.insert(category)
        context.insert(Category(apiId: "1", name: "Series", parentId: 0, type: .series, playlist: playlist))
        try context.save()

        let manager = ContentSyncManager(modelContainer: container)
        try await manager.syncProviderCategories([
            ProviderCategory(id: "1", name: "Renamed"),
            ProviderCategory(id: "2", name: "First"),
            ProviderCategory(id: "2", name: "Last", parentID: 9)
        ], type: .vod, playlistId: playlist.id)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Lume.Category>())
        #expect(rows.count == 3)
        let updated = try #require(rows.first { $0.type == .vod && $0.apiId == "1" })
        #expect(updated.id == "\(playlist.id.uuidString)-vod-1")
        #expect(updated.name == "Renamed")
        #expect(updated.parentId == 7)
        #expect(updated.isHidden && updated.isRestricted)
        #expect(updated.customOrder == 4)
        #expect(updated.customIcon == "star")
        #expect(updated.contentImportedAt == Date(timeIntervalSince1970: 100))
        let inserted = try #require(rows.first { $0.apiId == "2" })
        #expect(inserted.name == "Last")
        #expect(inserted.parentId == 9)
        #expect(inserted.sortOrder == 2)
        #expect(rows.first { $0.type == .series }?.name == "Series")

        // Repeated unusable category responses cannot spend sweep tolerance.
        for _ in 0 ..< 4 {
            try await manager.syncProviderCategories([ProviderCategory(id: "", name: "Invalid")], type: .vod, playlistId: playlist.id)
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Lume.Category>()) == 3)
        #expect(!SweepSkipDefaults.hasAny(playlistId: playlist.id))
    }
}

@Suite(.readsGlobalState)
struct XtreamEmptyCategoryTests {
    @Test func `xtream keeps a category whose provider id is empty`() async throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(name: "Xtream", serverURL: "https://example.test", username: "u", password: "p")
        context.insert(playlist)
        try context.save()
        let manager = ContentSyncManager(modelContainer: container)

        let rows = [ProviderCategory(id: "", name: "Uncategorised"), ProviderCategory(id: "1", name: "Films")]
        try await manager.syncProviderCategories(rows, type: .vod, playlistId: playlist.id, keepsEmptyIDs: true)
        try await manager.syncProviderCategories(rows, type: .vod, playlistId: playlist.id, keepsEmptyIDs: true)

        let ids = try Set(ModelContext(container).fetch(FetchDescriptor<Lume.Category>()).map(\.id))
        #expect(ids == ["\(playlist.id.uuidString)-vod-", "\(playlist.id.uuidString)-vod-1"])
    }
}

struct CatalogSweepPolicyTests {
    @Test func `only measured low coverage spends the shrink budget`() {
        #expect(CatalogSweepPolicy.decide(seenCount: 9, storedCount: 100, previousSkips: 0) == .hold(skips: 1))
        #expect(CatalogSweepPolicy.decide(seenCount: 9, storedCount: 100, previousSkips: 1) == .hold(skips: 2))
        #expect(CatalogSweepPolicy.decide(seenCount: 9, storedCount: 100, previousSkips: 2) == .acceptShrink(skips: 3))
        #expect(CatalogSweepPolicy.decide(seenCount: 10, storedCount: 100, previousSkips: 2) == .sweep)
        #expect(CatalogSweepPolicy.decide(seenCount: 0, storedCount: 0, previousSkips: 0) == .sweep)
        for skips in [0, 1, 2, 10] {
            #expect(CatalogSweepPolicy.decide(seenCount: 10, storedCount: nil, previousSkips: skips) == .unreadable)
        }
    }
}

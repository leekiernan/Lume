import Foundation
@testable import Lume
import SwiftData
import SwiftUI
import Testing

@MainActor
struct CatalogBrowseLoadMachineTests {
    private func category(stalker: Bool = false, stamp: Date? = nil) -> Lume.Category {
        let playlist = stalker
            ? Playlist(name: "Portal", portalURL: "https://example.com", macAddress: "00:11:22:33:44:55")
            : Playlist(name: "Playlist", m3uURL: "https://example.com/list.m3u")
        let category = Lume.Category(apiId: "1", name: "Movies", parentId: 0, typeRaw: "vod", playlist: playlist)
        category.contentImportedAt = stamp
        return category
    }

    private func categoryKey(_ category: Lume.Category, visibility: String = "visible", profile: UUID? = nil) -> CatalogCategoryKey {
        .init(categoryID: category.id, visibility: visibility, profile: profile)
    }

    @Test func `ordinary and fresh portal categories never import and preserve pages on reappearance`() async {
        for category in [category(), category(stalker: true, stamp: .now)] {
            let machine = CatalogCategoryLoadMachine<Int>(pageSize: 2)
            var imports = 0
            var offsets: [Int] = []
            let fetch: CatalogCategoryLoadMachine<Int>.Fetch = { _, offset, _ in
                offsets.append(offset)
                return offset == 0 ? [1, 2] : [3]
            }
            let importer: CatalogCategoryLoadMachine<Int>.Import = { _, _ in imports += 1 }
            await machine.open(category: category, key: categoryKey(category), fetch: fetch, importContent: importer)
            machine.loadNextPage(fetch: fetch)
            await machine.open(category: category, key: categoryKey(category), fetch: fetch, importContent: importer)
            #expect(imports == 0)
            #expect(offsets == [0, 2])
            #expect(machine.items == [1, 2, 3])
            #expect(!machine.pagination.canLoadMore)
        }
    }

    @Test func `first portal import precedes the local fetch and a failed import keeps cached rows usable`() async {
        let category = category(stalker: true)
        let machine = CatalogCategoryLoadMachine<Int>()
        var order: [String] = []
        await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in
            order.append("fetch")
            return [7]
        }, importContent: { _, _ in
            order.append("import")
            #expect(machine.isImporting)
            throw TestError.failed
        })
        #expect(order == ["import", "fetch"])
        #expect(machine.items == [7])
        #expect(!machine.isImporting)
    }

    @Test func `stale portal publishes its cached page before revalidation and replaces its loaded window`() async {
        let category = category(stalker: true, stamp: .distantPast)
        let machine = CatalogCategoryLoadMachine<Int>(pageSize: 2)
        var refreshed = false
        var windows: [Int] = []
        await machine.open(category: category, key: categoryKey(category), fetch: { _, _, limit in
            windows.append(limit)
            return refreshed ? [3, 4] : [1, 2]
        }, importContent: { _, _ in
            #expect(machine.items == [1, 2])
            refreshed = true
        })
        #expect(windows == [2, 2])
        #expect(machine.items == [3, 4])
        #expect(machine.pagination.nextOffset == 2)
    }

    @Test func `failed revalidation fetch preserves cached rows and failed first fetch can retry`() async {
        let category = category(stalker: true, stamp: .distantPast)
        let machine = CatalogCategoryLoadMachine<Int>(pageSize: 2)
        var attempts = 0
        await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in
            attempts += 1
            if attempts > 1 { throw TestError.failed }
            return [1, 2]
        }, importContent: { _, _ in })
        #expect(machine.items == [1, 2])
        #expect(machine.pagination.nextOffset == 2)

        let ordinary = self.category()
        await machine.open(category: ordinary, key: categoryKey(ordinary), fetch: { _, _, _ in throw TestError.failed }, importContent: { _, _ in })
        #expect(machine.items.isEmpty)
        #expect(machine.pagination.nextOffset == 0)
        await machine.open(category: ordinary, key: categoryKey(ordinary), fetch: { _, _, _ in [9] }, importContent: { _, _ in })
        #expect(machine.items == [9])
    }

    @Test func `an old import cannot publish or release the replacement scope's import ownership`() async {
        let category = category(stalker: true)
        let machine = CatalogCategoryLoadMachine<Int>()
        let old = BrowseGate<Void>()
        let new = BrowseGate<Void>()
        let task = Task {
            await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in [1] }, importContent: { _, _ in await old.wait() })
        }
        await old.started()
        let replacement = Task {
            await machine.open(category: category, key: categoryKey(category, visibility: "hidden", profile: UUID()),
                               fetch: { _, _, _ in [2] }, importContent: { _, _ in await new.wait() })
        }
        await new.started()
        old.release(())
        await task.value
        #expect(machine.items.isEmpty)
        #expect(machine.isImporting)
        new.release(())
        await replacement.value
        #expect(machine.items == [2])
        #expect(!machine.isImporting)
    }

    @Test func `cancelled first import remains retryable and manual refresh ignores duplicate work`() async {
        let category = category(stalker: true)
        let machine = CatalogCategoryLoadMachine<Int>()
        let gate = BrowseGate<Void>()
        let task = Task {
            await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in [1] }, importContent: { _, _ in await gate.wait() })
        }
        await gate.started()
        task.cancel()
        gate.release(())
        await task.value
        #expect(machine.items.isEmpty)
        await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in [2] }, importContent: { _, _ in })
        #expect(machine.items == [2])
        let refreshGate = BrowseGate<Void>()
        let refresh = Task {
            await machine.refresh(category: category, fetch: { _, _, _ in [3] }, importContent: { _, _ in await refreshGate.wait() })
        }
        await refreshGate.started()
        await machine.refresh(category: category, fetch: { _, _, _ in [4] }, importContent: { _, _ in Issue.record("duplicate import") })
        #expect(machine.items == [2])
        refreshGate.release(())
        await refresh.value
        #expect(machine.items == [3])
    }

    @Test func `reopening during an unfinished first import imports again and loads the page`() async {
        let category = category(stalker: true)
        let machine = CatalogCategoryLoadMachine<Int>()
        let gate = BrowseGate<Void>()
        let first = Task {
            await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in [1] }, importContent: { _, _ in await gate.wait() })
        }
        await gate.started()
        first.cancel()

        // Back before the cancelled import returns; it never stamps the category.
        var reimports = 0
        let reopen = Task {
            await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in [2] }, importContent: { _, _ in reimports += 1 })
        }
        await Task.yield()
        #expect(machine.items.isEmpty)
        gate.release(())
        await first.value
        await reopen.value
        #expect(reimports == 1)
        #expect(machine.items == [2])
    }

    @Test func `reopening during a first import that completes loads the page without importing again`() async {
        let category = category(stalker: true)
        let machine = CatalogCategoryLoadMachine<Int>()
        let gate = BrowseGate<Void>()
        let first = Task {
            await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in [1] }, importContent: { category, _ in
                await gate.wait()
                category.contentImportedAt = .now
            })
        }
        await gate.started()
        first.cancel()

        let reopen = Task {
            await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in [2] }, importContent: { _, _ in Issue.record("imported twice") })
        }
        await Task.yield()
        gate.release(())
        await first.value
        await reopen.value
        #expect(machine.items == [2])
    }

    @Test func `cached category keeps paging during revalidation and reloads the whole reached window`() async {
        let category = category(stalker: true, stamp: .distantPast)
        let machine = CatalogCategoryLoadMachine<Int>(pageSize: 2)
        var refreshed = false
        var windows: [Int] = []
        let fetch: CatalogCategoryLoadMachine<Int>.Fetch = { _, offset, limit in
            windows.append(limit)
            return Array((refreshed ? [5, 6, 7, 8] : [1, 2, 3, 4]).dropFirst(offset).prefix(limit))
        }
        await machine.open(category: category, key: categoryKey(category), fetch: fetch, importContent: { _, _ in
            machine.loadNextPage(fetch: fetch)
            #expect(machine.items == [1, 2, 3, 4])
            refreshed = true
        })
        #expect(windows == [2, 2, 4])
        #expect(machine.items == [5, 6, 7, 8])
        #expect(machine.pagination.nextOffset == 4)
    }

    @Test func `failed manual refresh fetch does not throw away the visible cached page`() async {
        let category = category(stalker: true, stamp: .now)
        let machine = CatalogCategoryLoadMachine<Int>()
        await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in [1] }, importContent: { _, _ in })
        await machine.refresh(category: category, fetch: { _, _, _ in throw TestError.failed }, importContent: { _, _ in })
        #expect(machine.items == [1])
        #expect(machine.pagination.nextOffset == 1)
    }

    @Test func `visibility invalidation clears category rows and rejects an already running import`() async {
        let category = category(stalker: true)
        let machine = CatalogCategoryLoadMachine<Int>()
        let gate = BrowseGate<Void>()
        let task = Task {
            await machine.open(category: category, key: categoryKey(category), fetch: { _, _, _ in [1] }, importContent: { _, _ in await gate.wait() })
        }
        await gate.started()
        machine.invalidate()
        gate.release(())
        await task.value
        #expect(machine.key == nil)
        #expect(machine.items.isEmpty)
        #expect(!machine.pagination.isPrepared)
        #expect(!machine.isImporting)
    }

    private func genreKey(_ genre: String = "Drama", prefix: String = "one-", visibility: String = "visible", profile: UUID? = nil) -> CatalogGenreKey {
        .init(genre: genre, playlistPrefix: prefix, visibility: visibility, profile: profile)
    }

    @Test func `genre scan advances by scanned source rows and drains empty budget pages`() async throws {
        let container = try makeTestContainer()
        let movie = Movie(id: "one", streamId: 1, name: "One")
        container.mainContext.insert(movie)
        try container.mainContext.save()
        let machine = CatalogGenreLoadMachine<Int>()
        var offsets: [Int] = []
        await machine.open(key: genreKey(), excluded: ["hidden"], fetch: { request in
            #expect(request.excludedCategoryIDs == ["hidden"])
            offsets.append(request.offset)
            return request.offset == 0
                ? GenrePage(ids: [], scanned: 500, reachedEnd: false)
                : GenrePage(ids: [movie.persistentModelID], scanned: 23, reachedEnd: true)
        }, hydrate: { _ in 7 })
        #expect(offsets == [0, 500])
        #expect(machine.items == [7])
        #expect(machine.pagination.nextOffset == 523)
        #expect(!machine.pagination.canLoadMore)
    }

    @Test func `genre hydration misses drain further pages and zero progress terminates`() async throws {
        let container = try makeTestContainer()
        let movie = Movie(id: "one", streamId: 1, name: "One")
        container.mainContext.insert(movie)
        try container.mainContext.save()
        let machine = CatalogGenreLoadMachine<Int>()
        var offsets: [Int] = []
        await machine.open(key: genreKey(), excluded: [], fetch: { request in
            offsets.append(request.offset)
            return GenrePage(ids: [movie.persistentModelID], scanned: request.offset == 0 ? 100 : 0, reachedEnd: false)
        }, hydrate: { _ in nil })
        #expect(offsets == [0, 100])
        #expect(machine.items.isEmpty)
        #expect(!machine.pagination.canLoadMore)
    }

    @Test(arguments: ["genre", "playlist", "visibility", "profile"])
    func `late genre scans cannot overwrite a replacement scope`(changed: String) async {
        let machine = CatalogGenreLoadMachine<Int>()
        let gate = BrowseGate<GenrePage>()
        let task = Task {
            await machine.open(key: genreKey(), excluded: [], fetch: { _ in await gate.wait() }, hydrate: { _ in 1 })
        }
        await gate.started()
        let replacement = genreKey(changed == "genre" ? "Comedy" : "Drama", prefix: changed == "playlist" ? "two-" : "one-",
                                   visibility: changed == "visibility" ? "hidden" : "visible", profile: changed == "profile" ? UUID() : nil)
        await machine.open(key: replacement, excluded: [], fetch: { _ in .init(ids: [], scanned: 3, reachedEnd: true) }, hydrate: { _ in 2 })
        gate.release(.init(ids: [], scanned: 900, reachedEnd: false))
        await task.value
        #expect(machine.key == replacement)
        #expect(machine.pagination.nextOffset == 3)
        #expect(!machine.pagination.canLoadMore)
    }

    @Test func `cancelled genre scan retries the unfinished offset and rejects its old completion`() async {
        let machine = CatalogGenreLoadMachine<Int>()
        let gate = BrowseGate<GenrePage>()
        let task = Task {
            await machine.open(key: genreKey(), excluded: [], fetch: { _ in await gate.wait() }, hydrate: { _ in 1 })
        }
        await gate.started()
        machine.cancel()
        await machine.open(key: genreKey(), excluded: [], fetch: { request in
            #expect(request.offset == 0)
            return .init(ids: [], scanned: 8, reachedEnd: true)
        }, hydrate: { _ in 2 })
        gate.release(.init(ids: [], scanned: 100, reachedEnd: false))
        await task.value
        #expect(machine.pagination.nextOffset == 8)
        #expect(!machine.pagination.canLoadMore)
    }

    @Test func `genre next-page cancellation retains rows and ownership while retrying the same cursor`() async throws {
        let container = try makeTestContainer()
        let movie = Movie(id: "one", streamId: 1, name: "One")
        container.mainContext.insert(movie)
        try container.mainContext.save()
        let machine = CatalogGenreLoadMachine<Int>()
        await machine.open(key: genreKey(), excluded: [], fetch: { _ in
            .init(ids: [movie.persistentModelID], scanned: 100, reachedEnd: false)
        }, hydrate: { _ in 1 })
        let old = BrowseGate<GenrePage>()
        let new = BrowseGate<GenrePage>()
        let oldTask = machine.requestNextPage(excluded: [], fetch: { request in
            #expect(request.offset == 100)
            return await old.wait()
        }, hydrate: { _ in 2 })
        await old.started()
        machine.cancel()
        #expect(machine.items == [1])
        let newTask = machine.requestNextPage(excluded: [], fetch: { request in
            #expect(request.offset == 100)
            return await new.wait()
        }, hydrate: { _ in 3 })
        await new.started()
        old.release(.init(ids: [movie.persistentModelID], scanned: 999, reachedEnd: false))
        // The old task may complete before or after the new one: neither order
        // may release the replacement's cursor or publish its rows.
        new.release(.init(ids: [movie.persistentModelID], scanned: 1, reachedEnd: true))
        await oldTask?.value
        await newTask?.value
        #expect(machine.items == [1, 3])
        #expect(machine.pagination.nextOffset == 101)
        #expect(!machine.pagination.canLoadMore)
    }

    @Test func `sidebar genres reject old responses and snapshots from other playlists visibility or profiles`() async {
        let machine = LibraryGenreLoadMachine()
        let first = LibraryGenreLoadKey(prefix: "one-", visibility: "all", profile: nil, syncedAt: nil)
        let second = LibraryGenreLoadKey(prefix: "two-", visibility: "child", profile: UUID(), syncedAt: .now)
        let gate = BrowseGate<[String]>()
        let task = Task { await machine.load(for: first) { await gate.wait() } }
        await gate.started()
        await machine.load(for: second) { ["Comedy"] }
        gate.release(["Drama"])
        await task.value
        #expect(machine.snapshot(for: first).isEmpty)
        #expect(machine.snapshot(for: second) == ["Comedy"])
        #expect(machine.snapshot(for: .init(prefix: second.prefix, visibility: "all", profile: second.profile, syncedAt: second.syncedAt)).isEmpty)
        #expect(machine.snapshot(for: .init(prefix: second.prefix, visibility: second.visibility, profile: UUID(), syncedAt: second.syncedAt)).isEmpty)
    }

    @Test func `a sync keeps the sidebar genres on screen until they are re-derived`() async {
        let machine = LibraryGenreLoadMachine()
        let before = LibraryGenreLoadKey(prefix: "one-", visibility: "all", profile: nil, syncedAt: .distantPast)
        await machine.load(for: before) { ["Drama"] }
        let after = LibraryGenreLoadKey(prefix: "one-", visibility: "all", profile: nil, syncedAt: .now)
        #expect(machine.snapshot(for: after) == ["Drama"])
        await machine.load(for: after) { ["Drama", "Comedy"] }
        #expect(machine.snapshot(for: after) == ["Drama", "Comedy"])
    }

    @Test func `cancelled sidebar derivation cannot replace a usable snapshot`() async {
        let machine = LibraryGenreLoadMachine()
        let key = LibraryGenreLoadKey(prefix: "one-", visibility: "all", profile: nil, syncedAt: nil)
        await machine.load(for: key) { ["Drama"] }
        let gate = BrowseGate<[String]>()
        let task = Task { await machine.load(for: key) { await gate.wait() } }
        await gate.started()
        task.cancel()
        gate.release(["Comedy"])
        await task.value
        #expect(machine.snapshot(for: key) == ["Drama"])
    }

    private enum TestError: Error { case failed }
}

/// Deterministic suspension: no timing sleeps or polling in ownership tests.
@MainActor
private final class BrowseGate<Value> {
    private var waiter: CheckedContinuation<Value, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            waiter = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func started() async {
        if waiter != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release(_ value: Value) {
        waiter?.resume(returning: value)
        waiter = nil
    }
}

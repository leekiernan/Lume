@testable import Lume
import Testing

struct PaginationMachineTests {
    @Test func `a same-offset retry cannot accept or abandon the failed attempt's request`() throws {
        var machine = PaginationMachine()
        machine.prepare(for: "collection")
        let begun14 = machine.beginLoading()
        let failed = try #require(begun14)
        let accepted6 = machine.abandon(failed)
        #expect(accepted6)
        let begun15 = machine.beginLoading()
        let retry = try #require(begun15)
        #expect(retry.offset == failed.offset)
        #expect(retry != failed)
        let accepted7 = machine.finish(failed, scanned: 100, hasMore: false)
        #expect(!accepted7)
        let accepted8 = machine.abandon(failed)
        #expect(!accepted8)
        #expect(machine.isLoading)
        let accepted9 = machine.finish(retry, scanned: 20, hasMore: false)
        #expect(accepted9)
        #expect(machine.nextOffset == 20)
    }

    @Test func `recreating a collection cannot reuse its old cursor request`() throws {
        var machine = PaginationMachine()
        machine.prepare(for: "same-collection")
        let begun16 = machine.beginLoading()
        let old = try #require(begun16)
        machine = PaginationMachine()
        machine.prepare(for: "same-collection")
        let begun17 = machine.beginLoading()
        let current = try #require(begun17)
        #expect(old != current)
        let accepted10 = machine.finish(old, scanned: 100, hasMore: false)
        #expect(!accepted10)
        let accepted11 = machine.abandon(old)
        #expect(!accepted11)
        #expect(machine.isLoading)
        #expect(machine.nextOffset == 0)
        let accepted12 = machine.finish(current, scanned: 20, hasMore: false)
        #expect(accepted12)
        let accepted13 = machine.finish(current, scanned: 20, hasMore: false)
        #expect(!accepted13)
        #expect(machine.nextOffset == 20)
    }

    @Test func `preparing a new query resets cursor but preserving a query does not`() throws {
        var machine = PaginationMachine()

        let preparedFavorites = machine.prepare(for: "favorites")
        #expect(preparedFavorites)
        let firstRequest = machine.beginLoading()
        let first = try #require(firstRequest)
        #expect(first.offset == 0)
        let finishedFirst = machine.finish(first, scanned: 100, hasMore: true)
        #expect(finishedFirst)
        #expect(machine.nextOffset == 100)

        let preservedFavorites = machine.prepare(for: "favorites")
        #expect(!preservedFavorites)
        #expect(machine.nextOffset == 100)

        let preparedRecent = machine.prepare(for: "recent")
        #expect(preparedRecent)
        let replacementRequest = machine.beginLoading()
        let replacement = try #require(replacementRequest)
        #expect(replacement.offset == 0)
    }

    @Test func `a stale page cannot overwrite a replacement query`() throws {
        var machine = PaginationMachine()
        let preparedPlaylistA = machine.prepare(for: "playlist-a")
        #expect(preparedPlaylistA)
        let staleRequest = machine.beginLoading()
        let stale = try #require(staleRequest)

        let preparedPlaylistB = machine.prepare(for: "playlist-b")
        #expect(preparedPlaylistB)
        let finishedStale = machine.finish(stale, scanned: 100, hasMore: true)
        #expect(!finishedStale)

        let currentRequest = machine.beginLoading()
        let current = try #require(currentRequest)
        #expect(current.offset == 0)
        let finishedCurrent = machine.finish(current, scanned: 25, hasMore: false)
        #expect(finishedCurrent)
        #expect(!machine.canLoadMore)
        #expect(machine.nextOffset == 25)
    }

    @Test func `abandoning a failed page keeps its cursor retryable`() throws {
        var machine = PaginationMachine()
        let preparedGenre = machine.prepare(for: "genre")
        #expect(preparedGenre)
        let failedRequest = machine.beginLoading()
        let failed = try #require(failedRequest)
        let abandonedFailed = machine.abandon(failed)
        #expect(abandonedFailed)

        let retryRequest = machine.beginLoading()
        let retry = try #require(retryRequest)
        #expect(retry.offset == 0)
        let finishedRetry = machine.finish(retry, scanned: 100, hasMore: true)
        #expect(finishedRetry)
        #expect(machine.nextOffset == 100)
    }

    @Test func `replacing a cached window invalidates an in-flight page`() throws {
        var machine = PaginationMachine()
        let preparedCustom = machine.prepare(for: "custom")
        #expect(preparedCustom)
        machine.seed(nextOffset: 20, canLoadMore: true)
        let staleRequest = machine.beginLoading()
        let stale = try #require(staleRequest)
        #expect(stale.offset == 20)

        machine.replaceWindow(scanned: 40, hasMore: true)
        let finishedStale = machine.finish(stale, scanned: 100, hasMore: false)
        #expect(!finishedStale)

        let nextRequest = machine.beginLoading()
        let next = try #require(nextRequest)
        #expect(next.offset == 40)
    }
}

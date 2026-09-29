@testable import Lume
import Testing

struct PaginationMachineTests {
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

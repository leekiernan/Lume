@testable import Lume
import Testing

struct SportsEventDetailLoadMachineTests {
    @Test func `recreated event detail rejects old completion and failure`() {
        var machine = SportsEventDetailLoadMachine()
        let stale = machine.begin()
        machine = SportsEventDetailLoadMachine()
        let current = machine.begin()
        #expect(stale != current)
        let accepted18 = machine.finish(stale, detail: nil)
        #expect(!accepted18)
        let accepted19 = machine.fail(stale)
        #expect(!accepted19)
        #expect(machine.isLoading)
        let accepted20 = machine.fail(current)
        #expect(accepted20)
        let accepted21 = machine.finish(current, detail: nil)
        #expect(!accepted21)
    }

    @Test func `a stale result cannot settle the replacement fixture request`() {
        var machine = SportsEventDetailLoadMachine()
        let stale = machine.begin()
        let current = machine.begin()

        let acceptedStaleResult = machine.finish(stale, detail: nil)
        #expect(!acceptedStaleResult)
        #expect(machine.isLoading)

        let acceptedCurrentResult = machine.finish(current, detail: nil)
        #expect(acceptedCurrentResult)
        #expect(!machine.isLoading)
        #expect(machine.isSettled)
        #expect(machine.detail == nil)
    }

    @Test func `a failure is terminal and a new request resets it`() {
        var machine = SportsEventDetailLoadMachine()
        let failed = machine.begin()

        let acceptedFailure = machine.fail(failed)
        #expect(acceptedFailure)
        #expect(machine.isSettled)
        #expect(!machine.isLoading)

        _ = machine.begin()
        #expect(machine.isLoading)
        #expect(!machine.isSettled)
    }
}

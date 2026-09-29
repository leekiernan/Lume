@testable import Lume
import Testing

struct SportsEventDetailLoadMachineTests {
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

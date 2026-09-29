@testable import Lume
import Testing

struct ImageDiskCacheMaintenanceMachineTests {
    @Test func `the first request starts maintenance and a completed pass returns to idle`() {
        var machine = ImageDiskCacheMaintenanceMachine()

        let startsFirstPass = machine.request()
        #expect(startsFirstPass)

        let needsSuccessor = machine.finishPass()
        #expect(!needsSuccessor)

        let startsNextPass = machine.request()
        #expect(startsNextPass)
    }

    @Test func `a burst while running coalesces into exactly one successor pass`() {
        var machine = ImageDiskCacheMaintenanceMachine()
        _ = machine.request()

        let startsSecondCaller = machine.request()
        let startsThirdCaller = machine.request()
        #expect(!startsSecondCaller)
        #expect(!startsThirdCaller)

        let needsSuccessor = machine.finishPass()
        #expect(needsSuccessor)

        let needsThirdPass = machine.finishPass()
        #expect(!needsThirdPass)
    }

    @Test func `invalidating accounting only requests a successor when maintenance is active`() {
        var machine = ImageDiskCacheMaintenanceMachine()
        machine.requestSuccessorIfRunning()

        let startsFirstPass = machine.request()
        #expect(startsFirstPass)

        machine.requestSuccessorIfRunning()
        let needsSuccessor = machine.finishPass()
        #expect(needsSuccessor)
    }
}

//
//  ReconcileScheduleMachineTests.swift
//  LumeTests
//
//  When iCloud sync runs a reconcile: one pass at a time, requests gathered
//  and run straight after, passes skipped when there's nothing to pull, a
//  retry when the catalog couldn't be read, and the launch gate.
//

@testable import Lume
import Testing

struct ReconcileScheduleMachineTests {
    private typealias Machine = ReconcileScheduleMachine

    /// A machine with a pass running for `reason`.
    private func running(_ reason: ReconcileReason = .launch) -> Machine {
        var machine = Machine()
        _ = machine.handle(.requested(reason, debounced: false))
        return machine
    }

    @Test func `a burst of requests runs once, after the debounce`() {
        var machine = Machine()
        #expect(machine.handle(.requested(.contentSync, debounced: true)) == [.startDebounce])
        #expect(machine.handle(.requested(.queued, debounced: true)) == [.startDebounce])
        #expect(machine.handle(.debounceElapsed) == [.runPass([.contentSync, .queued])])
        #expect(machine.state == .reconciling(followUp: []))
    }

    @Test func `a flush before suspension runs now`() {
        var machine = Machine()
        _ = machine.handle(.requested(.contentSync, debounced: true))
        #expect(machine.handle(.requested(.backgroundFlush, debounced: false))
            == [.cancelDebounce, .runPass([.contentSync, .backgroundFlush])])
    }

    @Test func `a foreground with nothing imported is skipped`() {
        var machine = Machine()
        #expect(machine.handle(.requested(.foreground, debounced: true)) == nil)
        #expect(machine.handle(.requested(.remoteChange, debounced: true)) == nil)
        _ = machine.handle(.importSeen)
        #expect(machine.handle(.requested(.foreground, debounced: true)) == [.startDebounce])
    }

    /// The pass pulls what was imported; an import during it counts again.
    @Test func `a pass consumes the import`() {
        var machine = Machine()
        _ = machine.handle(.importSeen)
        _ = machine.handle(.requested(.remoteChange, debounced: false))
        _ = machine.handle(.passFinished(.completed))
        #expect(machine.handle(.requested(.foreground, debounced: true)) == nil)
    }

    /// The old flags queued one anonymous follow-up and debounced it again.
    @Test func `requests during a pass run straight after, with their reasons`() {
        var machine = running()
        #expect(machine.handle(.requested(.contentSync, debounced: false)) == [.cancelDebounce])
        _ = machine.handle(.requested(.queued, debounced: true))
        #expect(machine.handle(.debounceElapsed) == [])
        #expect(machine.state == .reconciling(followUp: [.contentSync, .queued]))
        #expect(machine.handle(.passFinished(.completed)) == [.recordSync, .runPass([.contentSync, .queued])])
    }

    /// A pass that couldn't read the catalog isn't a sync, and is retried.
    @Test func `an unreadable catalog waits and retries`() {
        var machine = running()
        #expect(machine.handle(.passFinished(.catalogUnreadable)) == [.scheduleCatalogRetry])
        #expect(machine.state == .waitingForCatalog)
        #expect(machine.handle(.catalogRetryElapsed) == [.runPass([.catalogRetry])])
    }

    @Test func `a finished catalog sync retries too`() {
        var machine = running()
        _ = machine.handle(.passFinished(.catalogUnreadable))
        #expect(machine.handle(.requested(.contentSync, debounced: false)) == [.cancelDebounce, .runPass([.contentSync])])
        // The timer firing after is late, not a second retry.
        #expect(machine.handle(.catalogRetryElapsed) == nil)
    }

    @Test func `a failed pass isn't recorded as a sync`() {
        var machine = running()
        #expect(machine.handle(.passFinished(.failed)) == [])
        #expect(machine.state == .idle)
    }

    @Test func `the launch gate opens after the last queued pass`() {
        var machine = Machine()
        #expect(machine.handle(.initialSyncSettled) == [.startDebounce])
        #expect(machine.gate == .armed)
        _ = machine.handle(.debounceElapsed)
        _ = machine.handle(.requested(.contentSync, debounced: false))
        // A pass is queued behind: not yet.
        #expect(machine.handle(.passFinished(.completed)) == [.recordSync, .runPass([.contentSync])])
        #expect(machine.handle(.passFinished(.completed)) == [.recordSync, .openGate])
        #expect(machine.gate == .open)
        // Settling again changes nothing.
        #expect(machine.handle(.initialSyncSettled) == nil)
    }

    /// A fresh install mustn't be stranded on the spinner by a bad catalog.
    @Test func `the gate opens even when the catalog couldn't be read`() {
        var machine = Machine()
        _ = machine.handle(.initialSyncSettled)
        _ = machine.handle(.debounceElapsed)
        #expect(machine.handle(.passFinished(.catalogUnreadable)) == [.scheduleCatalogRetry, .openGate])
    }

    @Test func `skipping the wait opens the gate once`() {
        var machine = Machine()
        #expect(machine.handle(.gateSkipped) == [.openGate])
        #expect(machine.handle(.gateSkipped) == nil)
        #expect(Machine(gateOpen: true).gate == .open)
    }

    @Test func `a finished pass with nothing running is ignored`() {
        var machine = Machine()
        #expect(machine.handle(.passFinished(.completed)) == nil)
    }
}

import Foundation
@testable import Lume
import Observation
import Synchronization
import Testing

nonisolated struct PlayerChromeMachineTests {
    @Test func `deadlines retain the existing inactivity and pointer timings`() {
        #expect(PlayerChromeMachine.Deadline.inactivity.delay == .seconds(4))
        #expect(PlayerChromeMachine.Deadline.pointerExit.delay == .milliseconds(600))
    }

    @Test func `pointer exit replaces inactivity and later activity revokes both`() throws {
        var machine = PlayerChromeMachine()
        let first = machine.schedule(.inactivity, mayHide: true)
        let inactivity = try #require(first)
        let second = machine.schedule(.pointerExit, mayHide: true)
        let pointerExit = try #require(second)
        let third = machine.schedule(.inactivity, mayHide: true)
        let renewed = try #require(third)
        let oldFire = machine.fire(inactivity, mayHide: true)
        let pointerFire = machine.fire(pointerExit, mayHide: true)
        #expect(!oldFire && !pointerFire && machine.isVisible)
        let newFire = machine.fire(renewed, mayHide: true)
        #expect(newFire && !machine.isVisible)
    }

    @Test func `manual hide and show do not revive a pending deadline`() throws {
        var machine = PlayerChromeMachine()
        let begun = machine.schedule(.inactivity, mayHide: true)
        let request = try #require(begun)
        machine.hide()
        #expect(!machine.isVisible)
        let hiddenRequest = machine.schedule(.inactivity, mayHide: true)
        #expect(hiddenRequest == nil)
        machine.show()
        let staleFire = machine.fire(request, mayHide: true)
        #expect(!staleFire && machine.isVisible)
    }

    @Test func `pinned controls consume rather than postpone an expired deadline`() throws {
        var machine = PlayerChromeMachine()
        let begun = machine.schedule(.inactivity, mayHide: true)
        let request = try #require(begun)
        let pinnedFire = machine.fire(request, mayHide: false)
        let replay = machine.fire(request, mayHide: true)
        #expect(!pinnedFire && !replay && machine.isVisible)
        let pinnedRequest = machine.schedule(.pointerExit, mayHide: false)
        #expect(pinnedRequest == nil)
    }

    @Test func `scrubbing and disappearance cancel pending hides without losing visibility`() throws {
        var machine = PlayerChromeMachine()
        let begun = machine.schedule(.inactivity, mayHide: true)
        let request = try #require(begun)
        machine.cancelDeadline()
        let staleFire = machine.fire(request, mayHide: true)
        #expect(!staleFire && machine.isVisible)
    }

    @Test func `a recreated owner cannot consume the previous players deadline`() throws {
        var previous = PlayerChromeMachine()
        var current = PlayerChromeMachine()
        let oldBegun = previous.schedule(.inactivity, mayHide: true)
        let old = try #require(oldBegun)
        let newBegun = current.schedule(.inactivity, mayHide: true)
        let new = try #require(newBegun)
        let oldFire = current.fire(old, mayHide: true)
        let newFire = current.fire(new, mayHide: true)
        #expect(!oldFire && newFire && !current.isVisible)
    }
}

@MainActor
struct PlayerChromeControllerTests {
    @Test func `renewing deadlines does not invalidate a menus visibility dependency`() {
        let chrome = PlayerChromeController()
        chrome.activate()
        let changed = Mutex(false)
        withObservationTracking {
            _ = chrome.isVisible
        } onChange: {
            changed.withLock { $0 = true }
        }
        chrome.schedule(mayHide: { true })
        chrome.schedule(.pointerExit, mayHide: { true })
        chrome.show()
        chrome.suspend()
        #expect(!changed.withLock { $0 })
        chrome.hide()
        #expect(changed.withLock { $0 })
        chrome.deactivate()
    }

    @Test func `timer rechecks current playback panel and accessibility eligibility`() async throws {
        let gate = ChromeSleepGate()
        defer { gate.releaseAll() }
        let chrome = PlayerChromeController(sleep: gate.sleep)
        var playing = true
        var pinned = false
        var suppressed = false
        let eligibility = {
            PlayerControlsAutoHide.mayHide(isPlaying: playing, isPanelOpen: pinned, isSuppressed: suppressed)
        }
        chrome.activate()
        for reason in 0 ..< 3 {
            playing = true
            pinned = false
            suppressed = false
            chrome.schedule(mayHide: eligibility)
            try await waitUntil { gate.count == reason + 1 }
            #expect(gate.count == reason + 1)
            switch reason {
            case 0: playing = false
            case 1: pinned = true
            default: suppressed = true
            }
            gate.release(reason)
            try await waitUntil { gate.completed == reason + 1 }
            #expect(chrome.isVisible)
        }
        playing = true
        pinned = false
        suppressed = false
        chrome.schedule(mayHide: eligibility)
        try await waitUntil { gate.count == 4 }
        gate.release(3)
        try await waitUntil { !chrome.isVisible }
        #expect(!chrome.isVisible)
        chrome.deactivate()
    }

    @Test func `renewal suspend and teardown reject cancellation resistant sleeper completions`() async throws {
        let gate = ChromeSleepGate()
        defer { gate.releaseAll() }
        let chrome = PlayerChromeController(sleep: gate.sleep)
        chrome.activate()
        chrome.schedule(.pointerExit, mayHide: { true })
        try await waitUntil { gate.count == 1 }
        chrome.show()
        chrome.schedule(mayHide: { true })
        try await waitUntil { gate.count == 2 }
        gate.release(0)
        try await waitUntil { gate.completed == 1 }
        #expect(chrome.isVisible)
        chrome.suspend()
        gate.release(1)
        try await waitUntil { gate.completed == 2 }
        #expect(chrome.isVisible)
        chrome.schedule(mayHide: { true })
        try await waitUntil { gate.count == 3 }
        chrome.deactivate()
        gate.release(2)
        try await waitUntil { gate.completed == 3 }
        chrome.schedule(mayHide: { true })
        #expect(chrome.isVisible && gate.count == 3)
        chrome.activate()
        chrome.schedule(mayHide: { true })
        try await waitUntil { gate.count == 4 }
        gate.release(3)
        try await waitUntil { !chrome.isVisible }
        #expect(!chrome.isVisible)
        chrome.deactivate()
    }

    @Test func `manual toggle and hidden chrome never arm an automatic hide`() {
        let gate = ChromeSleepGate()
        defer { gate.releaseAll() }
        let chrome = PlayerChromeController(sleep: gate.sleep)
        chrome.activate()
        chrome.toggle()
        chrome.schedule(mayHide: { true })
        #expect(!chrome.isVisible && gate.count == 0)
        chrome.toggle()
        #expect(chrome.isVisible)
        chrome.schedule(mayHide: { false })
        #expect(gate.count == 0)
        chrome.deactivate()
    }
}

/// Intentionally ignores cancellation, so a late sleeper cannot prove safety
/// merely by throwing before the production callback runs.
@MainActor
private final class ChromeSleepGate {
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var count = 0
    private(set) var completed = 0

    func sleep(_: Duration) async {
        let id = count
        count += 1
        await withCheckedContinuation { waiters[id] = $0 }
        completed += 1
    }

    func release(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume()
    }

    func releaseAll() {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

//
//  PlaylistSwitchPresentationMachineTests.swift
//  LumeTests
//

@testable import Lume
import Testing

/// A mutating call can't sit inside `#expect`/`#require` — the macro captures
/// its operands immutably — so each one runs first and its result is checked.
struct PlaylistSwitchPresentationMachineTests {
    @Test func `a visible switch rejects a replacement request`() throws {
        var machine = PlaylistSwitchPresentationMachine()
        let begun = machine.begin(targetID: "first", targetName: "First", defersDueSync: false)
        let first = try #require(begun)

        #expect(machine.isSwitching)
        #expect(machine.targetName == "First")
        let replacement = machine.begin(targetID: "second", targetName: "Second", defersDueSync: false)
        #expect(replacement == nil)

        let applied = machine.apply(first)
        #expect(applied)
        machine.finish(first)
        #expect(!machine.isSwitching)
    }

    @Test func `a stale request cannot apply or dismiss the active request`() throws {
        var machine = PlaylistSwitchPresentationMachine()
        let firstBegun = machine.begin(targetID: "first", targetName: "First", defersDueSync: false)
        let first = try #require(firstBegun)
        let firstApplied = machine.apply(first)
        #expect(firstApplied)
        machine.finish(first)

        let secondBegun = machine.begin(targetID: "second", targetName: "Second", defersDueSync: false)
        let second = try #require(secondBegun)
        let staleApplied = machine.apply(first)
        #expect(!staleApplied)
        machine.finish(first)

        #expect(machine.isSwitching)
        #expect(machine.targetName == "Second")
        let secondApplied = machine.apply(second)
        #expect(secondApplied)
    }

    @Test func `due sync deferral belongs to its exact target and is one shot`() throws {
        var machine = PlaylistSwitchPresentationMachine()
        let begun = machine.begin(targetID: "cached", targetName: "Cached", defersDueSync: true)
        let request = try #require(begun)

        let applied = machine.apply(request)
        #expect(applied)
        let other = machine.consumeDueSyncDeferral(for: "other")
        #expect(!other)
        let consumed = machine.consumeDueSyncDeferral(for: "cached")
        #expect(consumed)
        let again = machine.consumeDueSyncDeferral(for: "cached")
        #expect(!again)
    }
}

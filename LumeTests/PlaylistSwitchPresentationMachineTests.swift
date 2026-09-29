//
//  PlaylistSwitchPresentationMachineTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct PlaylistSwitchPresentationMachineTests {
    @Test func `a visible switch rejects a replacement request`() throws {
        var machine = PlaylistSwitchPresentationMachine()
        let first = try #require(machine.begin(targetID: "first", targetName: "First", defersDueSync: false))

        #expect(machine.isSwitching)
        #expect(machine.targetName == "First")
        #expect(machine.begin(targetID: "second", targetName: "Second", defersDueSync: false) == nil)

        #expect(machine.apply(first))
        machine.finish(first)
        #expect(!machine.isSwitching)
    }

    @Test func `a stale request cannot apply or dismiss the active request`() throws {
        var machine = PlaylistSwitchPresentationMachine()
        let first = try #require(machine.begin(targetID: "first", targetName: "First", defersDueSync: false))
        #expect(machine.apply(first))
        machine.finish(first)

        let second = try #require(machine.begin(targetID: "second", targetName: "Second", defersDueSync: false))
        #expect(!machine.apply(first))
        machine.finish(first)

        #expect(machine.isSwitching)
        #expect(machine.targetName == "Second")
        #expect(machine.apply(second))
    }

    @Test func `due sync deferral belongs to its exact target and is one shot`() throws {
        var machine = PlaylistSwitchPresentationMachine()
        let request = try #require(machine.begin(targetID: "cached", targetName: "Cached", defersDueSync: true))

        #expect(machine.apply(request))
        #expect(!machine.consumeDueSyncDeferral(for: "other"))
        #expect(machine.consumeDueSyncDeferral(for: "cached"))
        #expect(!machine.consumeDueSyncDeferral(for: "cached"))
    }
}

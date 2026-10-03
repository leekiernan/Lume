//
//  SportsFixtureResolutionMachineTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import Testing

struct SportsFixtureResolutionMachineTests {
    private func fixture(_ id: String) -> SportsFixture {
        SportsFixture(
            id: id, leagueId: "espn:soccer/eng.1", leagueName: "", leagueAbbreviation: "",
            startDate: Date(timeIntervalSince1970: 1_800_000_000), status: SportsFixtureStatus(state: .scheduled)
        )
    }

    private func answer(_ ids: String...) -> [String: [ResolvedChannel]] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, []) })
    }

    @Test func `both passes of the active request publish`() throws {
        var machine = SportsFixtureResolutionMachine()
        let begun1 = machine.begin([fixture("a"), fixture("b")])
        let request = try #require(begun1)
        let soon = machine.publish(request, answer("a"))
        #expect(soon)
        #expect(machine.resolved.keys.sorted() == ["a"])
        let all = machine.publish(request, answer("a", "b"))
        #expect(all)
        #expect(machine.resolved.keys.sorted() == ["a", "b"])
    }

    @Test func `a superseded request can't overwrite the newer one`() throws {
        var machine = SportsFixtureResolutionMachine()
        let begun2 = machine.begin([fixture("a")])
        let old = try #require(begun2)
        let begun3 = machine.begin([fixture("b")])
        let current = try #require(begun3)
        let late = machine.publish(old, answer("a"))
        #expect(!late)
        let fresh = machine.publish(current, answer("b"))
        #expect(fresh)
        #expect(machine.resolved.keys.sorted() == ["b"])
    }

    @Test func `nothing to show clears the answer and supersedes what's in flight`() throws {
        var machine = SportsFixtureResolutionMachine()
        let begun4 = machine.begin([fixture("a")])
        let request = try #require(begun4)
        machine.publish(request, answer("a"))
        let none = machine.begin([])
        #expect(none == nil)
        #expect(machine.resolved.isEmpty)
        let late = machine.publish(request, answer("a"))
        #expect(!late)
    }

    @Test func `the request key follows the fixtures and the refresh signals`() {
        let key = SportsFixtureResolutionMachine.requestKey(for: [fixture("a"), fixture("b")], refreshingOn: [false])
        #expect(key == "a,b|false")
        #expect(key != SportsFixtureResolutionMachine.requestKey(for: [fixture("a"), fixture("b")], refreshingOn: [true]))
    }
}

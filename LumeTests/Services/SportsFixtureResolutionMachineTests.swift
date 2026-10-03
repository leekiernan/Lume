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
        let key = SportsFixtureResolutionMachine.requestKey(for: [fixture("a"), fixture("b")], visibilityToken: "parent", refreshingOn: [false])
        #expect(key == "parent|a,b|false")
        #expect(key != SportsFixtureResolutionMachine.requestKey(for: [fixture("a"), fixture("b")], visibilityToken: "parent", refreshingOn: [true]))
        #expect(key != SportsFixtureResolutionMachine.requestKey(for: [fixture("a"), fixture("b")], visibilityToken: "child", refreshingOn: [false]))
    }

    @Test func `visibility changes hide previous answers before the replacement task starts`() throws {
        var machine = SportsFixtureResolutionMachine()
        let begun = machine.begin([fixture("a")], visibilityToken: "parent")
        let request = try #require(begun)
        machine.publish(request, answer("a"))
        #expect(machine.resolved(for: "parent").keys.sorted() == ["a"])
        #expect(machine.resolved(for: "child").isEmpty)
    }

    @Test func `visibility changes clear answers and reject the prior scope's late pass`() throws {
        var machine = SportsFixtureResolutionMachine()
        let begun = machine.begin([fixture("a")], visibilityToken: "parent")
        let old = try #require(begun)
        machine.publish(old, answer("a"))
        let replacement = machine.begin([fixture("a")], visibilityToken: "child")
        let current = try #require(replacement)
        #expect(machine.resolved.isEmpty)
        let late = machine.publish(old, answer("a"))
        #expect(!late)
        #expect(machine.resolved(for: "child").isEmpty)
        machine.publish(current, answer("a"))
        #expect(machine.resolved(for: "child").keys.sorted() == ["a"])
        #expect(machine.resolved(for: "parent").isEmpty)
    }

    @Test func `refreshing the same visibility scope keeps its answer while loading`() throws {
        var machine = SportsFixtureResolutionMachine()
        let begun = machine.begin([fixture("a")], visibilityToken: "parent")
        let request = try #require(begun)
        machine.publish(request, answer("a"))
        _ = machine.begin([fixture("a")], visibilityToken: "parent")
        #expect(machine.resolved(for: "parent").keys.sorted() == ["a"])
    }
}

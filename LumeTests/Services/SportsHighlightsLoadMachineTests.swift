//
//  SportsHighlightsLoadMachineTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct SportsHighlightsLoadMachineTests {
    @Test func `keeps the previous rail visible while refreshing`() {
        var machine = SportsHighlightsLoadMachine()
        let first = machine.begin()
        let result = SportsHighlightsPipeline.Result(highlights: [], resolved: ["fixture": []])

        let appliedFirst = machine.finish(first, result: result)
        #expect(appliedFirst)
        let refresh = machine.begin()

        #expect(machine.isLoading)
        #expect(machine.result == result)
        let appliedRefresh = machine.finish(refresh, result: .init(highlights: [], resolved: [:]))
        #expect(appliedRefresh)
        #expect(!machine.isLoading)
    }

    @Test func `ignores a result from a superseded request`() {
        var machine = SportsHighlightsLoadMachine()
        let old = machine.begin()
        let current = machine.begin()
        let result = SportsHighlightsPipeline.Result(highlights: [], resolved: ["fixture": []])

        let appliedOld = machine.finish(old, result: result)
        #expect(!appliedOld)
        #expect(machine.isLoading)
        #expect(machine.result == .init(highlights: [], resolved: [:]))
        let appliedCurrent = machine.finish(current, result: result)
        #expect(appliedCurrent)
        #expect(machine.result == result)
    }
}

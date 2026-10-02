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

        #expect(machine.finish(first, result: result))
        let refresh = machine.begin()

        #expect(machine.isLoading)
        #expect(machine.result == result)
        #expect(machine.finish(refresh, result: .init(highlights: [], resolved: [:])))
        #expect(!machine.isLoading)
    }

    @Test func `ignores a result from a superseded request`() {
        var machine = SportsHighlightsLoadMachine()
        let old = machine.begin()
        let current = machine.begin()
        let result = SportsHighlightsPipeline.Result(highlights: [], resolved: ["fixture": []])

        #expect(!machine.finish(old, result: result))
        #expect(machine.isLoading)
        #expect(machine.result == .init(highlights: [], resolved: [:]))
        #expect(machine.finish(current, result: result))
        #expect(machine.result == result)
    }
}

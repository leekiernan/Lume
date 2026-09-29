//
//  PlaylistOnboardingMachineTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct PlaylistOnboardingMachineTests {
    @Test func `only one validation attempt can own the form`() {
        var machine = PlaylistOnboardingMachine()
        let attempt = machine.begin(.xtream)

        #expect(attempt != nil)
        #expect(machine.isValidating)
        #expect(machine.begin(.m3u) == nil)
    }

    @Test func `only the active attempt can complete the form`() throws {
        var machine = PlaylistOnboardingMachine()
        let active = try #require(machine.begin(.stalker))
        let stale = PlaylistOnboardingMachine.Attempt(id: UUID(), source: .stalker)

        #expect(!machine.succeed(stale))
        #expect(machine.isValidating)
        #expect(machine.succeed(active))
        #expect(!machine.isValidating)
        #expect(machine.errorMessage == nil)
    }

    @Test func `a failed attempt is retryable and clears its error on retry`() throws {
        var machine = PlaylistOnboardingMachine()
        let failed = try #require(machine.begin(.m3u))

        machine.fail(failed, message: "Could not connect")
        #expect(machine.errorMessage == "Could not connect")
        #expect(!machine.isValidating)

        let retry = machine.begin(.m3u)
        #expect(retry != nil)
        #expect(machine.errorMessage == nil)
        #expect(machine.isValidating)
    }

    @Test func `late failures cannot replace a newer form state`() throws {
        var machine = PlaylistOnboardingMachine()
        let first = try #require(machine.begin(.xtream))
        machine.fail(first, message: "First failure")
        let retry = try #require(machine.begin(.mediaServer))

        machine.fail(first, message: "Late failure")

        #expect(machine.isValidating)
        #expect(machine.succeed(retry))
        #expect(machine.errorMessage == nil)
    }

    @Test func `input errors use the same retryable error state`() {
        var machine = PlaylistOnboardingMachine()

        machine.reportInputFailure("Couldn't read file")
        #expect(machine.errorMessage == "Couldn't read file")

        machine.clearFailure()
        #expect(machine.errorMessage == nil)
    }
}

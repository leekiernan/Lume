//
//  SportsHeroSelectionMachineTests.swift
//  LumeTests
//

import Foundation
@testable import Lume
import Testing

struct SportsHeroSelectionMachineTests {
    private func candidate(
        _ id: String,
        tier: SportsHeroSelectionMachine.Tier,
        available: Bool = false
    ) -> SportsHeroSelectionMachine.Candidate {
        SportsHeroSelectionMachine.Candidate(
            fixture: SportsFixture(
                id: id, leagueId: "espn:soccer/eng.1", leagueName: "Premier League", leagueAbbreviation: "EPL",
                startDate: Date(timeIntervalSince1970: 1_800_000_000), status: SportsFixtureStatus(state: .scheduled)
            ),
            tier: tier,
            isAvailable: available
        )
    }

    @Test func `an available fixture wins within its semantic tier`() {
        let unavailable = candidate("first", tier: .live)
        let available = candidate("second", tier: .live, available: true)
        var machine = SportsHeroSelectionMachine()

        machine.reconcile(candidates: [unavailable, available], context: "today")

        #expect(machine.displayed(in: [unavailable, available], context: "today")?.id == "second")
    }

    @Test func `availability cannot let a lower tier outrank a live fixture`() {
        let live = candidate("live", tier: .live)
        let highlight = candidate("highlight", tier: .highlight, available: true)
        var machine = SportsHeroSelectionMachine()

        machine.reconcile(candidates: [live, highlight], context: "today")

        #expect(machine.displayed(in: [live, highlight], context: "today")?.id == "live")
    }

    @Test func `a partial resolver result cannot replace the displayed peer`() {
        let first = candidate("first", tier: .live)
        let second = candidate("second", tier: .live)
        var machine = SportsHeroSelectionMachine()
        machine.reconcile(candidates: [first, second], context: "today")

        let later = candidate("second", tier: .live, available: true)
        machine.reconcile(candidates: [first, later], context: "today")

        #expect(machine.displayed(in: [first, later], context: "today")?.id == "first")
    }

    @Test func `a higher semantic tier can promote over the current hero`() {
        let highlight = candidate("highlight", tier: .highlight)
        var machine = SportsHeroSelectionMachine()
        machine.reconcile(candidates: [highlight], context: "today")

        let live = candidate("live", tier: .live)
        machine.reconcile(candidates: [live, highlight], context: "today")

        #expect(machine.displayed(in: [live, highlight], context: "today")?.id == "live")
    }

    @Test func `a stale hero is replaced by the current preferred candidate`() {
        let live = candidate("live", tier: .live)
        let highlight = candidate("highlight", tier: .highlight)
        var machine = SportsHeroSelectionMachine()
        machine.reconcile(candidates: [live, highlight], context: "today")

        machine.reconcile(candidates: [highlight], context: "today")

        #expect(machine.displayed(in: [highlight], context: "today")?.id == "highlight")
    }

    @Test func `a scope change immediately displays the new context candidate`() {
        let today = candidate("today", tier: .live)
        let upcoming = candidate("upcoming", tier: .primaryUpcoming)
        var machine = SportsHeroSelectionMachine()
        machine.reconcile(candidates: [today], context: "today")

        #expect(machine.displayed(in: [upcoming], context: "upcoming")?.id == "upcoming")
    }
}

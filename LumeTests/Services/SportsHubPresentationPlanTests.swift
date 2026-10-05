import Foundation
@testable import Lume
import Testing

struct SportsHubPresentationPlanTests {
    private func fixture(_ id: String, name: String = "League") -> SportsFixture {
        SportsFixture(
            id: id, leagueId: "espn:soccer/eng.1", leagueName: name, leagueAbbreviation: "EPL",
            startDate: Date(timeIntervalSince1970: 1_800_000_000), status: SportsFixtureStatus(state: .scheduled)
        )
    }

    private func candidate(_ id: String) -> SportsHeroSelectionMachine.Candidate {
        .init(fixture: fixture(id), tier: .highlight, isAvailable: false)
    }

    @Test func `both surfaces resolve every displayed slide and only remove their own slides from rows`() {
        let candidates = (0 ..< 10).map { candidate("game-\($0)") }
        let fixtures = candidates.map(\.fixture)
        let standard = SportsHubPresentationPlan(fixtures: fixtures, candidates: candidates, surface: .standard)
        let television = SportsHubPresentationPlan(fixtures: fixtures, candidates: candidates, surface: .television)

        #expect(standard.carousel.map(\.id) == Array(candidates.prefix(5)).map(\.id))
        #expect(television.carousel.map(\.id) == Array(candidates.prefix(8)).map(\.id))
        #expect(standard.rowFixtures.map(\.id) == Array(fixtures.dropFirst(5)).map(\.id))
        #expect(television.rowFixtures.map(\.id) == Array(fixtures.dropFirst(8)).map(\.id))
        #expect(standard.resolutionFixtures == fixtures)
        #expect(television.resolutionFixtures == fixtures)
    }

    @Test func `off-row slides and the displayed highlights rail join one deduplicated resolution pass`() {
        let candidates = (0 ..< 10).map { candidate("game-\($0)") }
        let plan = SportsHubPresentationPlan(
            fixtures: [fixture("row"), fixture("game-0", name: "Fresh snapshot"), fixture("row")],
            candidates: candidates, surface: .standard,
            highlights: [fixture("game-3"), fixture("highlight-rail")]
        )
        #expect(plan.resolutionFixtures.map(\.id) == ["row", "game-0", "game-1", "game-2", "game-3", "game-4", "highlight-rail"])
        #expect(plan.resolutionFixtures[1].leagueName == "Fresh snapshot")
        #expect(!plan.resolutionFixtures.contains { $0.id == "game-5" })
    }

    @Test func `carousel-only content is not an empty hub`() {
        let pick = candidate("pick")
        let plan = SportsHubPresentationPlan(fixtures: [pick.fixture], candidates: [pick], surface: .standard)
        #expect(plan.rowFixtures.isEmpty)
        #expect(!plan.showsNoGames(groupsAreEmpty: true))
        #expect(!plan.showsNoGames(groupsAreEmpty: false))
    }

    @Test func `a genuinely empty hub shows no games but populated rows do not`() {
        let empty = SportsHubPresentationPlan(fixtures: [], candidates: [], surface: .television)
        #expect(empty.showsNoGames(groupsAreEmpty: true))
        let rows = SportsHubPresentationPlan(fixtures: [fixture("row")], candidates: [], surface: .standard)
        #expect(!rows.showsNoGames(groupsAreEmpty: false))
    }

    @Test func `guide refresh and slide changes supersede requests without weakening visibility isolation`() throws {
        let plan = SportsHubPresentationPlan(fixtures: [], candidates: [candidate("a"), candidate("b")], surface: .standard)
        let ready = SportsFixtureResolutionMachine.requestKey(for: plan.resolutionFixtures, visibilityToken: "parent", refreshingOn: [false])
        let syncing = SportsFixtureResolutionMachine.requestKey(for: plan.resolutionFixtures, visibilityToken: "parent", refreshingOn: [true])
        #expect(ready != syncing)

        var machine = SportsFixtureResolutionMachine()
        let begun = machine.begin(plan.resolutionFixtures, visibilityToken: "parent")
        let old = try #require(begun)
        machine.publish(old, ["a": [], "b": []])
        let replacement = SportsHubPresentationPlan(fixtures: [], candidates: [candidate("b"), candidate("c")], surface: .standard)
        let newKey = SportsFixtureResolutionMachine.requestKey(for: replacement.resolutionFixtures, visibilityToken: "parent", refreshingOn: [false])
        #expect(ready != newKey)
        let begunAgain = machine.begin(replacement.resolutionFixtures, visibilityToken: "child")
        let current = try #require(begunAgain)
        #expect(machine.resolved(for: "child").isEmpty)
        let rejected = machine.publish(old, ["a": [], "b": []])
        #expect(!rejected)
        let accepted = machine.publish(current, ["b": [], "c": []])
        #expect(accepted)
        #expect(machine.resolved(for: "child").keys.sorted() == ["b", "c"])
    }

    @Test func `the plan retains the selection machines stable lead through partial availability`() {
        let first = candidate("first")
        let peer = candidate("peer")
        var selection = SportsHeroSelectionMachine()
        selection.reconcile(candidates: [first, peer], context: "today")
        let availablePeer = SportsHeroSelectionMachine.Candidate(fixture: peer.fixture, tier: peer.tier, isAvailable: true)
        selection.reconcile(candidates: [first, availablePeer], context: "today")
        let plan = SportsHubPresentationPlan(
            fixtures: [], candidates: selection.carouselCandidates(in: [first, availablePeer], context: "today"), surface: .television
        )
        #expect(plan.carousel.map(\.id) == ["first", "peer"])
        #expect(plan.resolutionFixtures.map(\.id) == ["first", "peer"])
    }
}

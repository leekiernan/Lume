//
//  SportsScoreRevealTests.swift
//  LumeTests
//
//  "Hold to reveal" under Hide Scores: one game at a time, remembered on this
//  device, forgotten after a fortnight.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct SportsScoreRevealTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        let name = "SportsScoreRevealTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test func `a reveal shows that game only`() {
        let reveal = SportsScoreReveal(defaults: defaults(), now: now)
        reveal.reveal("game-1", now: now)

        let shown = SportsFixture(
            id: "game-1", leagueId: "espn:soccer/eng.1", leagueName: "", leagueAbbreviation: "",
            startDate: now, status: SportsFixtureStatus(state: .final)
        )
        let other = SportsFixture(
            id: "game-2", leagueId: "espn:soccer/eng.1", leagueName: "", leagueAbbreviation: "",
            startDate: now, status: SportsFixtureStatus(state: .final)
        )
        #expect(shown.showsScore(hidingScores: true, reveal: reveal))
        #expect(!other.showsScore(hidingScores: true, reveal: reveal))
        #expect(other.showsScore(hidingScores: false, reveal: reveal))
    }

    @Test func `reveals survive a restart and expire after a fortnight`() {
        let store = defaults()
        SportsScoreReveal(defaults: store, now: now).reveal("game-1", now: now)

        #expect(SportsScoreReveal(defaults: store, now: now.addingTimeInterval(86400)).isRevealed("game-1"))
        #expect(!SportsScoreReveal(defaults: store, now: now.addingTimeInterval(15 * 86400)).isRevealed("game-1"))
    }
}

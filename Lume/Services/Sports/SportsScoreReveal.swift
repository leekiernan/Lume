//
//  SportsScoreReveal.swift
//  Lume
//
//  With Hide Scores on, a finished game can still be revealed on its own —
//  "hold to reveal" on its card. The reveal is remembered on this device so the
//  game doesn't hide again on the next visit, and forgotten after a fortnight,
//  by when nobody is saving it to watch.
//

import Foundation

@MainActor
@Observable
final class SportsScoreReveal {
    static let shared = SportsScoreReveal()

    static let defaultsKey = "sports.revealedScores.v1"
    static let retention: TimeInterval = 14 * 86400

    private let defaults: UserDefaults
    /// Fixture id → when it was revealed.
    private(set) var revealed: [String: Date]

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        let stored = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Date]) ?? [:]
        revealed = stored.filter { now.timeIntervalSince($0.value) < Self.retention }
    }

    func isRevealed(_ fixtureId: String) -> Bool {
        revealed[fixtureId] != nil
    }

    func reveal(_ fixtureId: String, now: Date = Date()) {
        revealed[fixtureId] = now
        defaults.set(revealed, forKey: Self.defaultsKey)
    }
}

extension SportsFixture {
    /// Whether this fixture's score shows, given the Hide Scores setting and
    /// any reveal of this one game.
    @MainActor
    func showsScore(hidingScores: Bool, reveal: SportsScoreReveal) -> Bool {
        !hidingScores || reveal.isRevealed(id)
    }
}

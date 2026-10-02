//
//  SportsAlertMachine.swift
//  Lume
//
//  Decides which in-player sports alerts to raise, from successive snapshots
//  of the viewer's followed games. Pure: the coordinator feeds it each live
//  poll's fixtures and shows what it returns.
//
//  The first sighting of a game only records it — opening the app mid-match
//  must not replay the goals already scored. After that a score that rises is
//  a goal (or score), a game leaving "scheduled" is kick-off, half-time and
//  the final whistle are their own events, and every alert is raised once.
//  The game the viewer is watching never alerts — the stream runs behind the
//  data and the alert would spoil what's about to happen — but its state is
//  still tracked, so switching away doesn't replay it.
//

import Foundation

nonisolated struct SportsAlert: Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case score
        case kickoff
        case halfTime
        case finalResult
    }

    let fixture: SportsFixture
    let kind: Kind
    /// For a score: the side that scored, when only one side's score moved.
    let scoringTeamId: String?

    /// Stable per event, so a re-delivered snapshot never raises it twice.
    var id: String {
        "\(fixture.id)|\(kind.rawValue)|\(fixture.home?.displayScore ?? "")-\(fixture.away?.displayScore ?? "")"
    }
}

nonisolated struct SportsAlertMachine {
    /// What was last seen of a game.
    private struct Memory: Equatable {
        let state: SportsFixtureState
        let homeScore: String?
        let awayScore: String?
        let atHalfTime: Bool
    }

    private var memory: [String: Memory] = [:]
    private var raised: Set<String> = []

    /// Feeds one poll's view of the followed games; returns the alerts to show,
    /// oldest event first.
    mutating func observe(
        _ fixtures: [SportsFixture],
        settings: SportsAlertSettings,
        watchingFixtureId: String?
    ) -> [SportsAlert] {
        var alerts: [SportsAlert] = []
        for fixture in fixtures where fixture.hasTeams {
            let now = Memory(
                state: fixture.status.state,
                homeScore: fixture.home?.displayScore,
                awayScore: fixture.away?.displayScore,
                atHalfTime: fixture.status.phase == .halftime
            )
            defer { memory[fixture.id] = now }
            guard let before = memory[fixture.id], before != now else { continue }
            guard fixture.id != watchingFixtureId else { continue }

            for kind in Self.changes(from: before, to: now) where settings.alerts(kind, sport: fixture.sport) {
                let alert = SportsAlert(
                    fixture: fixture,
                    kind: kind,
                    scoringTeamId: kind == .score ? Self.scorer(fixture, before: before) : nil
                )
                if raised.insert(alert.id).inserted {
                    alerts.append(alert)
                }
            }
        }
        return alerts
    }

    private static func changes(from before: Memory, to now: Memory) -> [SportsAlert.Kind] {
        var kinds: [SportsAlert.Kind] = []
        if before.state == .scheduled, now.state == .inProgress {
            kinds.append(.kickoff)
        }
        let scoreMoved = before.homeScore != now.homeScore || before.awayScore != now.awayScore
        if scoreMoved, now.state == .inProgress || now.state == .final, before.state != .scheduled {
            kinds.append(.score)
        }
        if !before.atHalfTime, now.atHalfTime {
            kinds.append(.halfTime)
        }
        if before.state != .final, now.state == .final {
            kinds.append(.finalResult)
        }
        return kinds
    }

    private static func scorer(_ fixture: SportsFixture, before: Memory) -> String? {
        let homeMoved = before.homeScore != fixture.home?.displayScore
        let awayMoved = before.awayScore != fixture.away?.displayScore
        if homeMoved, !awayMoved { return fixture.home?.team.id }
        if awayMoved, !homeMoved { return fixture.away?.team.id }
        return nil
    }
}

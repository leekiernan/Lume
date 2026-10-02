//
//  SportsTeamSeason.swift
//  Lume
//
//  A football team's season at a glance: one card per competition it is in,
//  each drawn the way that competition works — a league as its table around
//  the team, a UEFA league phase as a place among 36 with the qualification
//  bands, a cup as the path of rounds so far and to come — plus the squad's
//  leaders. The builder is pure; `SportsTeamSeasonLoader` feeds it.
//

import Foundation

nonisolated struct SportsTeamSeason: Equatable {
    let team: SportsTeam
    let competitions: [SportsSeasonCompetition]
    let leaders: [SportsLeaderBoard]
    /// The competition the leader numbers cover (the domestic league).
    let leadersCompetitionName: String?
}

nonisolated struct SportsSeasonCompetition: Identifiable, Equatable {
    enum Format: Equatable {
        case table(SportsTableSnapshot)
        case leaguePhase(SportsLeaguePhase)
        case knockout([SportsKnockoutStep])
    }

    let leagueId: String
    let name: String
    let format: Format
    /// The team's next game in it, if one is scheduled.
    let next: SportsFixture?

    var id: String {
        leagueId
    }
}

nonisolated struct SportsTableSnapshot: Equatable {
    let position: Int
    let points: Int?
    let played: Int?
    /// A few rows either side of the team.
    let rows: [SportsStandingRow]
    let teamRowId: String
}

nonisolated struct SportsLeaguePhase: Equatable {
    let position: Int
    let total: Int
    let points: Int?
    let played: Int?
    let bands: [SportsStandingBand]
}

/// A run of places that earn the same thing ("Qualifies for round of 16").
nonisolated struct SportsStandingBand: Equatable {
    let first: Int
    let last: Int
    let label: String
    let colorHex: String?
}

nonisolated struct SportsKnockoutStep: Equatable {
    enum State: Equatable {
        case won
        case lost
        case drawn
        case live
        case next
        case upcoming
    }

    let round: String
    let state: State
    let opponent: String?
    /// "4–2" for a played tie, else nothing.
    let score: String?
    let date: Date
}

nonisolated struct SportsLeaderBoard: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case goals
        case assists
        case appearances
        case saves
    }

    struct Entry: Equatable {
        let name: String
        let value: Int
    }

    let kind: Kind
    let entries: [Entry]

    var id: String {
        kind.rawValue
    }
}

/// One player's numbers in one competition.
nonisolated struct SportsPlayerSeasonLine: Equatable {
    let name: String
    let position: String?
    let appearances: Int
    let goals: Int
    let assists: Int
    let saves: Int
}

nonisolated enum SportsTeamSeasonBuilder {
    /// European football's season turns over in summer: everything from the
    /// last 1 July on is this season.
    static func seasonStart(now: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month], from: now)
        if let month = components.month, month < 7, let year = components.year {
            components.year = year - 1
        }
        components.month = 7
        components.day = 1
        return calendar.date(from: components) ?? now
    }

    /// What is known of one competition for one team.
    struct CompetitionInput {
        let name: String
        let leagueId: String
        let isDomesticLeague: Bool
        let fixtures: [SportsFixture]
        let standings: [SportsStandingRow]
    }

    /// The card for one competition, or `nil` when the team has no part in it
    /// this season.
    static func competition(_ input: CompetitionInput, teamId: String, now: Date) -> SportsSeasonCompetition? {
        let name = input.name, leagueId = input.leagueId
        let fixtures = input.fixtures, standings = input.standings
        let start = seasonStart(now: now)
        let season = fixtures
            .filter { $0.startDate >= start && involves($0, teamId) }
            .sorted { $0.startDate < $1.startDate }
        let next = season.first { $0.status.state == .scheduled }
        let tableRows = standings.filter { $0.kind == .team }

        if input.isDomesticLeague {
            guard let table = table(tableRows, teamId: teamId) else { return nil }
            return SportsSeasonCompetition(leagueId: leagueId, name: name, format: .table(table), next: next)
        }
        guard !season.isEmpty else { return nil }
        let knockoutGames = season.filter { !isLeaguePhase($0.round) }
        if knockoutGames.isEmpty, let phase = leaguePhase(tableRows, teamId: teamId) {
            return SportsSeasonCompetition(leagueId: leagueId, name: name, format: .leaguePhase(phase), next: next)
        }
        let steps = knockoutSteps(knockoutGames, teamId: teamId)
        return SportsSeasonCompetition(leagueId: leagueId, name: name, format: .knockout(steps), next: next)
    }

    static func isLeaguePhase(_ round: String?) -> Bool {
        guard let round = round?.lowercased() else { return false }
        return round.contains("league phase") || round.contains("league stage") || round.contains("group")
    }

    static func involves(_ fixture: SportsFixture, _ teamId: String) -> Bool {
        fixture.home?.team.teamId == teamId || fixture.away?.team.teamId == teamId
    }

    /// The team's row with two either side (more at the ends of the table).
    static func table(_ rows: [SportsStandingRow], teamId: String) -> SportsTableSnapshot? {
        let ordered = rows.sorted { $0.rank < $1.rank }
        guard let index = ordered.firstIndex(where: { $0.teamId == teamId }) else { return nil }
        let lower = max(0, min(index - 2, ordered.count - 5))
        let window = Array(ordered[lower ..< min(ordered.count, lower + 5)])
        let row = ordered[index]
        return SportsTableSnapshot(position: row.rank, points: row.points, played: row.played, rows: window, teamRowId: row.id)
    }

    static func leaguePhase(_ rows: [SportsStandingRow], teamId: String) -> SportsLeaguePhase? {
        let ordered = rows.sorted { $0.rank < $1.rank }
        guard let row = ordered.first(where: { $0.teamId == teamId }) else { return nil }
        return SportsLeaguePhase(
            position: row.rank, total: ordered.count, points: row.points, played: row.played, bands: bands(ordered)
        )
    }

    /// Consecutive places sharing a note, as bands. Unmarked places between
    /// them form no band.
    static func bands(_ rows: [SportsStandingRow]) -> [SportsStandingBand] {
        var bands: [SportsStandingBand] = []
        for row in rows.sorted(by: { $0.rank < $1.rank }) {
            guard let note = row.note, !note.isEmpty else { continue }
            if let last = bands.last, last.label == note, last.last == row.rank - 1 {
                bands[bands.count - 1] = SportsStandingBand(first: last.first, last: row.rank, label: note, colorHex: last.colorHex)
            } else {
                bands.append(SportsStandingBand(first: row.rank, last: row.rank, label: note, colorHex: row.noteColorHex))
            }
        }
        return bands
    }

    static func knockoutSteps(_ games: [SportsFixture], teamId: String) -> [SportsKnockoutStep] {
        var sawNext = false
        return games.map { game in
            let isHome = game.home?.team.teamId == teamId
            let mine = isHome ? game.home : game.away
            let theirs = isHome ? game.away : game.home
            let state: SportsKnockoutStep.State
            switch game.status.state {
            case .final:
                if mine?.isWinner == true {
                    state = .won
                } else if theirs?.isWinner == true {
                    state = .lost
                } else {
                    state = .drawn
                }
            case .inProgress:
                state = .live
                sawNext = true
            case .scheduled, .postponed:
                state = sawNext ? .upcoming : .next
                sawNext = true
            }
            let score = game.status.state == .final
                ? "\(mine?.displayScore ?? "0")–\(theirs?.displayScore ?? "0")"
                : nil
            return SportsKnockoutStep(
                round: game.round ?? game.leagueName,
                state: state,
                opponent: theirs?.team.shortName,
                score: score,
                date: game.startDate
            )
        }
    }

    /// The top three for each board, leaving out boards nobody has scored on.
    static func leaders(_ players: [SportsPlayerSeasonLine]) -> [SportsLeaderBoard] {
        SportsLeaderBoard.Kind.allCases.compactMap { kind in
            let entries = players
                .map { SportsLeaderBoard.Entry(name: $0.name, value: value(of: kind, $0)) }
                .filter { $0.value > 0 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
                .prefix(3)
            return entries.isEmpty ? nil : SportsLeaderBoard(kind: kind, entries: Array(entries))
        }
    }

    private static func value(of kind: SportsLeaderBoard.Kind, _ line: SportsPlayerSeasonLine) -> Int {
        switch kind {
        case .goals: line.goals
        case .assists: line.assists
        case .appearances: line.appearances
        case .saves: line.saves
        }
    }
}

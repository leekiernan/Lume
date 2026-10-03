//
//  SportsRacingSeason.swift
//  Lume
//
//  A race series' season in numbers, derived from its weekends' results:
//  wins (first in the race), poles (first in qualifying) and podiums (top
//  three in the race), beside each driver's points from the standings — and
//  the title picture: who leads, by how much, with how many races left.
//

import Foundation
import Synchronization

nonisolated struct SportsRacingSeason: Equatable {
    struct Driver: Equatable, Identifiable {
        let name: String
        let rank: Int
        let points: Int?
        let wins: Int
        let poles: Int
        let podiums: Int

        var id: String {
            name
        }
    }

    let drivers: [Driver]
    let racesLeft: Int

    /// The leader's margin over second, when both have points.
    var leadMargin: (leader: String, margin: Int)? {
        guard drivers.count >= 2, let first = drivers[0].points, let second = drivers[1].points else { return nil }
        return (drivers[0].name, first - second)
    }

    /// Driver standings joined with counts from `weekends`.
    static func build(weekends: [SportsFixture], standings: [SportsStandingRow], now: Date) -> SportsRacingSeason {
        var wins: [String: Int] = [:], poles: [String: Int] = [:], podiums: [String: Int] = [:]
        var racesLeft = 0
        for weekend in weekends {
            for session in weekend.sessions {
                guard let order = session.classification, !order.isEmpty else {
                    if session.kind == .race, session.date > now { racesLeft += 1 }
                    continue
                }
                switch session.kind {
                case .race:
                    wins[order[0], default: 0] += 1
                    for name in order.prefix(3) {
                        podiums[name, default: 0] += 1
                    }
                case .qualifying:
                    poles[order[0], default: 0] += 1
                default:
                    break
                }
            }
        }
        let drivers = standings
            .filter { $0.kind == .driver }
            .sorted { $0.rank < $1.rank }
            .map { row in
                Driver(
                    name: row.name, rank: row.rank, points: row.points,
                    wins: wins[row.name] ?? 0, poles: poles[row.name] ?? 0, podiums: podiums[row.name] ?? 0
                )
            }
        return SportsRacingSeason(drivers: drivers, racesLeft: racesLeft)
    }
}

/// Loads a racing series' whole season of weekends (one scoreboard month at a
/// time) and its standings, kept for an hour in memory.
nonisolated enum SportsRacingSeasonLoader {
    private static let lifetime: TimeInterval = 3600
    private static let cache = Mutex<[String: (season: SportsRacingSeason, at: Date)]>([:])

    static func load(league: SportsLeague, client: ESPNClient = .shared, now: Date = Date()) async -> SportsRacingSeason? {
        if let cached = cache.withLock({ $0[league.id] }), now.timeIntervalSince(cached.at) < lifetime {
            return cached.season
        }
        let year = Calendar.current.component(.year, from: now)
        async let weekends = withTaskGroup(of: [SportsFixture].self) { group in
            for month in 1 ... 12 {
                group.addTask { await (try? client.fixtures(league: league, month: DateComponents(year: year, month: month))) ?? [] }
            }
            var all: [String: SportsFixture] = [:]
            for await batch in group {
                for fixture in batch {
                    all[fixture.id] = fixture
                }
            }
            return Array(all.values)
        }
        async let standings = (try? client.standings(league: league)) ?? []
        let season = await SportsRacingSeason.build(weekends: weekends, standings: standings, now: now)
        guard !season.drivers.isEmpty else { return nil }
        cache.withLock { $0[league.id] = (season, now) }
        return season
    }
}

nonisolated extension SportsSession {
    /// "Russell · Verstappen · Hadjar" — the top three by surname, once the
    /// session has a result.
    var podiumLine: String? {
        guard let order = classification, !order.isEmpty else { return nil }
        return order.prefix(3).map { $0.split(separator: " ").last.map(String.init) ?? $0 }.joined(separator: " · ")
    }
}

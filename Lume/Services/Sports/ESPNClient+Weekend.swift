//
//  ESPNClient+Weekend.swift
//  Lume
//
//  A race weekend's status, read across its sessions (split from
//  ESPNClient.swift, at its length limit).
//

import Foundation

nonisolated extension ESPNClient {
    /// A race weekend's own status mirrors its first session: ESPN calls the
    /// whole weekend "Final" once FP1 is over, with the race still to come or
    /// under way. The weekend is live while any session is, else wherever the
    /// race stands; the event's status only when no session reports one.
    static func weekendStatus(_ event: ESPNEvent) -> SportsFixtureStatus {
        let competitions = event.competitions ?? []
        let sessionStatuses = competitions.compactMap(\.status).map(mapStatus)
        if let live = sessionStatuses.first(where: { $0.state == .inProgress }) {
            return live
        }
        let race = competitions.last { $0.type?.abbreviation == SportsSessionKind.race.rawValue } ?? competitions.last
        return race?.status.map(mapStatus) ?? mapStatus(event.status)
    }

    /// A race weekend's sessions, each with its state and — once run — its
    /// finishing order.
    static func mapSessions(_ event: ESPNEvent) -> [SportsSession] {
        (event.competitions ?? []).compactMap { comp in
            guard let raw = comp.type?.abbreviation,
                  let kind = SportsSessionKind(rawValue: raw),
                  let date = parseDate(comp.date)
            else { return nil }
            let order = (comp.competitors ?? []).sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            let classification = order.compactMap { $0.athlete?.displayName }
            return SportsSession(
                kind: kind, date: date, state: comp.status.map { mapStatus($0).state },
                classification: classification.isEmpty ? nil : classification
            )
        }
    }
}

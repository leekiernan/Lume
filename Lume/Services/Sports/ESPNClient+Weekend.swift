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
}

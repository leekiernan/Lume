import Foundation

nonisolated extension SportsTeam {
    /// A follow uses the provider-qualified team id, not the provider-local
    /// `teamId`: "espn:soccer/ger.1:132" belongs to "espn:soccer/ger.1".
    /// Reject missing/empty league prefixes; this does not validate a provider.
    static func leagueID(fromTeamID id: String) -> String? {
        guard let separator = id.lastIndex(of: ":"), separator > id.startIndex else { return nil }
        return String(id[..<separator])
    }
}

nonisolated extension SportsFixture {
    /// Follow identities are league/provider-qualified. A bare team number
    /// must not match the same number in an unrelated competition.
    func involves(anyOf teamIDs: Set<String>) -> Bool {
        if let home = home?.team.id, teamIDs.contains(home) { return true }
        if let away = away?.team.id, teamIDs.contains(away) { return true }
        return false
    }
}

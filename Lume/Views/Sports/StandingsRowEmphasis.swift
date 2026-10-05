/// Presentation context for a standings row. Being in the viewed fixture is
/// independent of following a team: highlight both opponents, but never give
/// an unfollowed opponent a following star.
nonisolated struct StandingsRowEmphasis: Equatable {
    let isFollowed: Bool
    let isPlaying: Bool

    init(row: SportsStandingRow, followedTeamIds: Set<String>, playingTeamIds: Set<String>) {
        isFollowed = followedTeamIds.containsFollowedTeam(for: row)
        isPlaying = row.kind == .team && row.teamId.map(playingTeamIds.contains) == true
    }

    var backgroundOpacity: Double {
        if isPlaying { return 0.16 }
        return isFollowed ? 0.08 : 0
    }
}

nonisolated extension SportsFixture {
    /// Raw provider IDs, matching the rows of this fixture's league table.
    /// No competitors (e.g. a race weekend) means no participant highlight.
    var standingsTeamIds: Set<String> {
        Set([home?.team.teamId, away?.team.teamId].compactMap(\.self).filter { !$0.isEmpty })
    }
}

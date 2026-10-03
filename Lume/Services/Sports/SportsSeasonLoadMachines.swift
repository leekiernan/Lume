//
//  SportsSeasonLoadMachines.swift
//  Lume
//
//  Presentation state for a season a Sports screen loads on demand: a team's
//  (its page, on both platforms) and a race series' (the match centre, on
//  both). Each is keyed by what it's for, so a result for a team or series no
//  longer on screen — one that survived task cancellation — is inert, and a
//  load that comes back empty settles rather than spinning.
//

/// A team page's season: its competitions, leaders and games.
nonisolated struct SportsTeamSeasonLoadMachine: Equatable {
    struct Request: Equatable {
        fileprivate let generation: UInt
        fileprivate let teamId: String
    }

    private enum State: Equatable {
        case idle
        case loading(Request)
        case loaded(teamId: String, season: SportsTeamSeason)
        case unavailable(teamId: String)
    }

    private var generation: UInt = 0
    private var state: State = .idle

    /// The season, while it belongs to `teamId`.
    func season(for teamId: String) -> SportsTeamSeason? {
        guard case let .loaded(id, season) = state, id == teamId else { return nil }
        return season
    }

    func isLoading(_ teamId: String) -> Bool {
        guard case let .loading(request) = state else { return false }
        return request.teamId == teamId
    }

    mutating func begin(teamId: String) -> Request {
        generation &+= 1
        let request = Request(generation: generation, teamId: teamId)
        state = .loading(request)
        return request
    }

    /// Applies a result only if it still belongs to the active load.
    @discardableResult
    mutating func finish(_ request: Request, season: SportsTeamSeason?) -> Bool {
        guard state == .loading(request) else { return false }
        state = season.map { .loaded(teamId: request.teamId, season: $0) } ?? .unavailable(teamId: request.teamId)
        return true
    }
}

/// A race series' season in the match centre.
nonisolated struct SportsRacingSeasonLoadMachine: Equatable {
    struct Request: Equatable {
        fileprivate let generation: UInt
        fileprivate let leagueId: String
    }

    private enum State: Equatable {
        case idle
        case loading(Request)
        case loaded(leagueId: String, season: SportsRacingSeason)
        case unavailable(leagueId: String)
    }

    private var generation: UInt = 0
    private var state: State = .idle

    /// The season, while it belongs to `leagueId`.
    func season(for leagueId: String) -> SportsRacingSeason? {
        guard case let .loaded(id, season) = state, id == leagueId else { return nil }
        return season
    }

    mutating func begin(leagueId: String) -> Request {
        generation &+= 1
        let request = Request(generation: generation, leagueId: leagueId)
        state = .loading(request)
        return request
    }

    @discardableResult
    mutating func finish(_ request: Request, season: SportsRacingSeason?) -> Bool {
        guard state == .loading(request) else { return false }
        state = season.map { .loaded(leagueId: request.leagueId, season: $0) } ?? .unavailable(leagueId: request.leagueId)
        return true
    }
}

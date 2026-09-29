//
//  SportsEventDetailLoadMachine.swift
//  Lume
//
//  Terminal-state and stale-result ownership for the extra event data a game
//  detail screen requests after its fixture header is already available.
//

/// Owns one fixture-keyed event-detail request. The game sheets retain their
/// own channel resolution and standings cache because those have independent
/// lifecycles; this machine represents only timeline, statistics and lineups.
nonisolated struct SportsEventDetailLoadMachine: Equatable {
    struct Request: Equatable {
        fileprivate let generation: UInt
    }

    private enum State: Equatable {
        case idle
        case loading(Request)
        case content(SportsEventDetail)
        case unavailable
        case failed
    }

    private var generation: UInt = 0
    private var state: State = .idle

    var detail: SportsEventDetail? {
        guard case let .content(detail) = state else { return nil }
        return detail
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var isSettled: Bool {
        switch state {
        case .content, .unavailable, .failed:
            true
        case .idle, .loading:
            false
        }
    }

    /// Clears a previous fixture's terminal state and grants ownership to its
    /// new request. The generation makes a provider result from the old sheet
    /// inert if it survives task cancellation.
    mutating func begin() -> Request {
        generation &+= 1
        let request = Request(generation: generation)
        state = .loading(request)
        return request
    }

    /// Applies a result only if it still belongs to the active fixture load.
    @discardableResult
    mutating func finish(_ request: Request, detail: SportsEventDetail?) -> Bool {
        guard state == .loading(request) else { return false }
        state = if let detail { .content(detail) } else { .unavailable }
        return true
    }

    /// A transport or decoding failure is terminal for this presentation. A
    /// later fixture gets a new request rather than inheriting this failure.
    @discardableResult
    mutating func fail(_ request: Request) -> Bool {
        guard state == .loading(request) else { return false }
        state = .failed
        return true
    }
}

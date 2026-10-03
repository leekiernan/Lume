//
//  SportsFixtureResolutionMachine.swift
//  Lume
//
//  The channels a screen's fixtures resolved to, and which request owns them.
//  Every Sports surface — both hubs, both Home rails, the league screen —
//  resolves the fixtures it shows off the main thread, in one or two passes
//  (soonest games first, then the rest), and re-runs when its fixtures or a
//  guide sync change. This owns what they shared by copy: the request's
//  identity, clearing when nothing is shown, and keeping a superseded pass
//  from overwriting a newer one. Grouping and rendering stay per platform.
//

import Foundation

nonisolated struct SportsFixtureResolutionMachine: Equatable {
    struct Request: Equatable {
        fileprivate let generation: UInt
    }

    private var generation: UInt = 0
    private var active: Request?
    /// Fixture id → the channels carrying it, as last published.
    private(set) var resolved: [String: [ResolvedChannel]] = [:]

    /// The `.task(id:)` identity for resolving `fixtures`: the set shown, and
    /// whatever else should prompt a fresh pass — a guide sync starting or
    /// ending, a catalog sync settling.
    static func requestKey(for fixtures: [SportsFixture], refreshingOn signals: [Bool] = []) -> String {
        ([fixtures.map(\.id).joined(separator: ",")] + signals.map { String($0) }).joined(separator: "|")
    }

    /// Starts a request for `fixtures`, superseding any in flight. With none
    /// to show, clears the answer and returns `nil`: there is nothing to run.
    mutating func begin(_ fixtures: [SportsFixture]) -> Request? {
        generation &+= 1
        guard !fixtures.isEmpty else {
            active = nil
            resolved = [:]
            return nil
        }
        let request = Request(generation: generation)
        active = request
        return request
    }

    /// Publishes a pass's answer if it still belongs to the active request —
    /// a first, soonest-games pass and the full one alike.
    @discardableResult
    mutating func publish(_ request: Request, _ answer: [String: [ResolvedChannel]]) -> Bool {
        guard request == active else { return false }
        resolved = answer
        return true
    }
}

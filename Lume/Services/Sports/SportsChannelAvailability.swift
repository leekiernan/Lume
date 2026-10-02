//
//  SportsChannelAvailability.swift
//  Lume
//
//  What a fixture card says about the viewer's own channels: nothing until the
//  resolver has answered, "Not on your channels" when it found none, otherwise
//  how many carry it. Upcoming games show it too, not only live ones — knowing
//  a game will be on your channels is the point of the hub.
//

import Foundation

nonisolated enum SportsChannelAvailability: Equatable {
    /// The resolver hasn't answered for this fixture yet.
    case unknown
    case none
    /// Distinct channels carrying it, and the one a Play press would open.
    case available(count: Int, best: ResolvedChannel)

    /// How far ahead "not on your channels" can be claimed. Guides rarely run
    /// further than a day or two, so an empty answer for next weekend means
    /// "no guide yet", not "not carried".
    static let guideHorizon: TimeInterval = 36 * 3600

    /// `resolved` is the resolver's answer for one fixture, `nil` when it has
    /// none yet. The same channel offered by two playlists counts once.
    init(
        _ resolved: [ResolvedChannel]?,
        startDate: Date,
        preference: SportsChannelPreference.Context? = nil,
        now: Date = Date()
    ) {
        guard let resolved = resolved.map({ channels in
            preference.map { SportsChannelPreference.ordered(channels, context: $0) } ?? channels
        }) else {
            self = .unknown
            return
        }
        guard let best = resolved.first else {
            self = startDate.timeIntervalSince(now) > Self.guideHorizon ? .unknown : .none
            return
        }
        let distinct = Set(resolved.map { $0.stream.name.lowercased().trimmingCharacters(in: .whitespaces) })
        self = .available(count: distinct.count, best: best)
    }

    /// The card's channel line, or `nil` when there is nothing to say yet.
    var label: String? {
        switch self {
        case .unknown:
            nil
        case .none:
            String(localized: "Not in your channels")
        case let .available(count, _) where count == 1:
            String(localized: "On your channels")
        case let .available(count, _):
            String(localized: "On \(count) of your channels")
        }
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

//
//  SportsAlertSettings.swift
//  Lume
//
//  A profile's in-player alert settings: when alerts may show (off, only over
//  Live TV, or over everything — films included), and which events each sport
//  raises. Stored as one JSON string under a profile-scoped key, so it follows
//  the person between devices like their other layout choices.
//
//  Off by default — interrupting a film is the viewer's call. Each sport's
//  default events suit how it scores: a goal is news, a basket is not.
//

import Foundation

nonisolated struct SportsAlertSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case off
        case liveTV
        case everything

        var id: String {
            rawValue
        }
    }

    var mode: Mode = .off
    /// Per sport ("soccer", "basketball"), the events chosen; a sport absent
    /// here uses `defaultEvents(for:)`.
    var events: [String: Set<SportsAlert.Kind>] = [:]

    /// The profile-scoped storage key's base name.
    static let baseKey = "sports.alertSettings.v1"

    init(mode: Mode = .off, events: [String: Set<SportsAlert.Kind>] = [:]) {
        self.mode = mode
        self.events = events
    }

    /// From the stored string; anything unreadable is the defaults.
    init(raw: String) {
        self = (try? JSONDecoder().decode(Self.self, from: Data(raw.utf8))) ?? Self()
    }

    var raw: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    func events(for sport: String) -> Set<SportsAlert.Kind> {
        events[sport] ?? Self.defaultEvents(for: sport)
    }

    func alerts(_ kind: SportsAlert.Kind, sport: String) -> Bool {
        events(for: sport).contains(kind)
    }

    mutating func set(_ kind: SportsAlert.Kind, _ isOn: Bool, sport: String) {
        var chosen = events(for: sport)
        if isOn { chosen.insert(kind) } else { chosen.remove(kind) }
        events[sport] = chosen
    }

    /// Goals and the result where scoring is rare; only the result where it
    /// is constant.
    static func defaultEvents(for sport: String) -> Set<SportsAlert.Kind> {
        switch sport {
        case "soccer", "hockey", "rugby", "rugby-league", "football", "australian-football", "lacrosse":
            [.score, .finalResult]
        case "basketball", "baseball", "cricket", "tennis":
            [.finalResult]
        default:
            []
        }
    }

    /// The sports alerts can be set for — those with two sides to score.
    static let sports: [String] = [
        "soccer", "football", "basketball", "hockey", "baseball", "rugby", "rugby-league",
        "australian-football", "cricket", "tennis", "lacrosse"
    ]
}

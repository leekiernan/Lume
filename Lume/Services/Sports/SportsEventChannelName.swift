//
//  SportsEventChannelName.swift
//  Lume
//
//  Event channels rarely have a guide; their provider renames them to the
//  event instead. The common shape is
//
//      US|NFHS Tue 12:00 - Somersworth vs. Laconia
//      US|SWAC No event
//      US|NFHS LIVE - Fife vs. Orting
//      US (PPV 05) | UFC 310 Pantoja vs Asakura
//
//  — a region and service, then a day and time (or LIVE), then the event after
//  " - ". This reads the event and its start out of a name, and an event out of
//  a category named for one ("UFC Fight Night | Rosas Jr vs Barcelos (Sat)").
//
//  Times are taken in the device's time zone: providers write them for their
//  own audience, which is the viewer's.
//

import Foundation

nonisolated enum SportsEventChannelName {
    struct Parsed: Equatable {
        let title: String
        let start: Date?
        let isLive: Bool
    }

    /// The event a channel's name carries, or `nil` for a placeholder ("No
    /// event") or a bare channel name ("US: PPV 05").
    static func parse(_ name: String, now: Date, calendar: Calendar = .current) -> Parsed? {
        if let dash = name.range(of: " - ") {
            let head = String(name[..<dash.lowerBound])
            let title = name[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !SportsPayPerView.isPlaceholder(title, channelName: head) else { return nil }
            let words = head.split(whereSeparator: { $0 == " " || $0 == "|" })
            let isLive = words.contains { $0.uppercased() == "LIVE" }
            return Parsed(title: title, start: isLive ? nil : start(in: words, now: now, calendar: calendar), isLive: isLive)
        }
        let segments = name
            .split(whereSeparator: { "|:()[]".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let candidates = segments.filter { segment in
            let haystack = SportsMatcher.normalize(segment)
            let letters = segment.unicodeScalars.filter(CharacterSet.letters.contains).count
            return haystack.split(separator: " ").count >= 2 && letters >= 6
                && !SportsPayPerView.isPlaceholder(segment, channelName: name)
                && !endsInPlaceholder(haystack)
        }
        return candidates.max { $0.count < $1.count }.map { Parsed(title: $0, start: nil, isLive: false) }
    }

    /// The event a category is named for: "UFC Fight Night | Rosas Jr vs
    /// Barcelos (Sat)" → "UFC Fight Night: Rosas Jr vs Barcelos". Only a
    /// matchup counts — "LIVE | Rugby (Sat)" names a sport, not an event.
    static func event(inCategory name: String) -> String? {
        let parts = name
            .replacingOccurrences(of: #"\s*\((Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\)"#, with: "", options: .regularExpression)
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.contains(where: isMatchup) else { return nil }
        return parts.joined(separator: ": ")
    }

    static func isMatchup(_ text: some StringProtocol) -> Bool {
        SportsMatcher.normalize(String(text)).contains(" vs ") || SportsMatcher.normalize(String(text)).contains(" v ")
    }

    /// "US|SWAC No event": a service name followed by the placeholder.
    private static func endsInPlaceholder(_ haystack: String) -> Bool {
        let trimmed = haystack.trimmingCharacters(in: .whitespaces)
        return ["no event", "no events", "off air"].contains { trimmed.hasSuffix($0) }
    }

    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// "Tue 12:00" → the next such moment, allowing for one already a few
    /// hours under way.
    private static func start(in words: [Substring], now: Date, calendar: Calendar) -> Date? {
        for (index, word) in words.enumerated() where index + 1 < words.count {
            guard let weekday = weekdays.firstIndex(of: String(word.lowercased().prefix(3))),
                  word.count <= 9
            else { continue }
            let clock = words[index + 1].split(separator: ":")
            guard clock.count == 2, let hour = Int(clock[0]), let minute = Int(clock[1]),
                  (0 ..< 24).contains(hour), (0 ..< 60).contains(minute)
            else { continue }
            let components = DateComponents(hour: hour, minute: minute, weekday: weekday + 1)
            return calendar.nextDate(
                after: now.addingTimeInterval(-6 * 3600), matching: components, matchingPolicy: .nextTime
            )
        }
        return nil
    }
}

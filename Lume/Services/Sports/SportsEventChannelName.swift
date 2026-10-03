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
        // A full date in the name — "… UCF Fri 2 Oct 7:00 PM EDT" — comes out
        // before splitting, or its "7:00" would split the title in two.
        let dated = datedStart(in: name, now: now, calendar: calendar)
        let rest = dated.map { name.replacingCharacters(in: $0.range, with: " ") } ?? name
        let segments = rest
            .split(whereSeparator: { "|:()[]".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let candidates = segments.filter { segment in
            let haystack = SportsMatcher.normalize(segment)
            let letters = segment.unicodeScalars.filter(CharacterSet.letters.contains).count
            return haystack.split(separator: " ").count >= 2 && letters >= 6
                && !SportsPayPerView.isPlaceholder(segment, channelName: name)
                && !endsInPlaceholder(haystack)
        }
        // A matchup names the event better than whatever else is longest.
        let best = candidates.filter(isMatchup).max { $0.count < $1.count } ?? candidates.max { $0.count < $1.count }
        return best.map { Parsed(title: $0, start: dated?.date, isLive: false) }
    }

    // MARK: - Dates

    /// Zone abbreviations a provider writes, by what they mean. Only these
    /// are trusted: a date with no zone, or one not listed, is read in the
    /// device's own zone, as the "Tue 12:00" form is.
    static let zones: [String: String] = [
        "ET": "America/New_York", "EST": "America/New_York", "EDT": "America/New_York",
        "CT": "America/Chicago", "CST": "America/Chicago", "CDT": "America/Chicago",
        "MT": "America/Denver", "MST": "America/Denver", "MDT": "America/Denver",
        "PT": "America/Los_Angeles", "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
        "UK": "Europe/London", "GMT": "Europe/London", "BST": "Europe/London",
        "CET": "Europe/Paris", "CEST": "Europe/Paris", "UTC": "UTC",
        "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney"
    ]

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthPattern = "(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\.?"
    /// Only a listed zone is consumed, so a word after the time ("… 8PM UFC")
    /// stays in the title.
    private static let timePattern = "(\\d{1,2})(?::(\\d{2}))?\\s*([AaPp][Mm])?(?:\\s+("
        + zones.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")\\b)?"
    /// "Fri 2 Oct 7:00 PM EDT", "2nd Oct 19:30", and "Oct 2, 7:00PM ET".
    private static let dayFirst = try? NSRegularExpression(
        pattern: "(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\\.?,?\\s+)?(\\d{1,2})(?:st|nd|rd|th)?\\s+" + monthPattern + ",?\\s+" + timePattern
    )
    private static let monthFirst = try? NSRegularExpression(
        pattern: "(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*\\.?,?\\s+)?" + monthPattern + "\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+" + timePattern
    )

    /// A dated start in `name`, and where it sits. A time needs minutes or
    /// AM/PM, so a bare number is never read as one.
    static func datedStart(in name: String, now: Date, calendar: Calendar = .current) -> (date: Date, range: Range<String.Index>)? {
        let whole = NSRange(name.startIndex..., in: name)
        for (regex, dayFirstOrder) in [(dayFirst, true), (monthFirst, false)] {
            guard let regex, let match = regex.firstMatch(in: name, range: whole),
                  let range = Range(match.range, in: name)
            else { continue }
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: name).map { String(name[$0]) }
            }
            let dayText = group(dayFirstOrder ? 1 : 2), monthText = group(dayFirstOrder ? 2 : 1)
            guard let dayText, let day = Int(dayText), let monthText,
                  let month = months.firstIndex(of: String(monthText.lowercased().prefix(3))),
                  let hourText = group(3), var hour = Int(hourText)
            else { continue }
            let minute = group(4).flatMap(Int.init)
            let meridiem = group(5)?.lowercased()
            guard minute != nil || meridiem != nil else { continue }
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
            var zoned = calendar
            if let zone = group(6).flatMap({ zones[$0] }).flatMap(TimeZone.init(identifier:)) { zoned.timeZone = zone }
            // The year isn't written: the nearest one that puts the date no more
            // than a month behind.
            let year = zoned.component(.year, from: now)
            for candidate in [year, year + 1] {
                let components = DateComponents(year: candidate, month: month + 1, day: day, hour: hour, minute: minute ?? 0)
                if let date = zoned.date(from: components), date > now.addingTimeInterval(-30 * 86400) {
                    return (date, range)
                }
            }
        }
        return nil
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

import Foundation

/// Aggregator ratings and when their source fetched them: the proxy's
/// `ratings` stamp, or the moment of a direct MDBList call.
nonisolated struct LumeTitleRatings: Equatable {
    let ratings: [ExternalRating]
    let fetchedAt: Date
}

/// How long a title's ratings stay fresh. Ratings move fastest just after
/// release, so the window depends on the title's age; it matches the proxy's
/// refresh schedule, so a device re-asks soon after the proxy has newer data.
nonisolated enum RatingsFreshness {
    static let newRelease: TimeInterval = 24 * 3600
    static let recent: TimeInterval = 7 * 24 * 3600
    static let settled: TimeInterval = 14 * 24 * 3600

    /// Unreleased or out under 30 days: a day. Under a year, or an unknown
    /// date: a week. Older: 14 days.
    static func window(releaseDate: String?, now: Date = Date()) -> TimeInterval {
        guard let released = releaseDay(releaseDate) else { return recent }
        let age = now.timeIntervalSince(released)
        if age < 30 * 24 * 3600 { return newRelease }
        return age < 365 * 24 * 3600 ? recent : settled
    }

    /// Whether ratings fetched at `fetchedAt` are still inside the window. A
    /// future date (clock skew) is never fresh.
    static func isFresh(_ fetchedAt: Date?, releaseDate: String?, now: Date = Date()) -> Bool {
        guard let fetchedAt, fetchedAt <= now else { return false }
        return now.timeIntervalSince(fetchedAt) < window(releaseDate: releaseDate, now: now)
    }

    /// Provider release dates arrive as `yyyy-MM-dd`, with a time appended, or
    /// as a bare year, taken as mid-year: neither "new" all year nor never.
    static func releaseDay(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), raw.count >= 4 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        if parts.count == 3, (1 ... 12).contains(parts[1]), (1 ... 31).contains(parts[2]) {
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let year = Int(raw.prefix(4)), year > 1800 else { return nil }
        return calendar.date(from: DateComponents(year: year, month: 7, day: 1))
    }
}

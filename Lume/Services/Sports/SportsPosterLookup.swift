import Foundation

/// Providers have unrelated event IDs. Prefer a miss over a different meeting.
nonisolated enum SportsPosterLookup {
    struct Event: Decodable {
        let idLeague: String?
        let strSport: String?
        let dateEvent: String?
        let strEvent: String?
        let strHomeTeam: String?
        let strAwayTeam: String?
        let strPoster: String?
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func poster(in events: [Event], fixture: SportsFixture, leagueID: String, sport: String) -> URL? {
        let matches = events.filter { event in
            guard event.idLeague == leagueID, event.strSport == sport, event.dateEvent == day(fixture.startDate) else { return false }
            if let home = fixture.home?.team.name, let away = fixture.away?.team.name {
                return event.strHomeTeam.map(normalized) == normalized(home)
                    && event.strAwayTeam.map(normalized) == normalized(away)
            }
            guard let name = fixture.name else { return false }
            return event.strEvent.map(normalized) == normalized(name)
        }
        guard matches.count == 1 else { return nil }
        return imageURL(matches[0].strPoster)
    }

    static func imageURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

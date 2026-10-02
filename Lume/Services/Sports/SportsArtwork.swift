//
//  SportsArtwork.swift
//  Lume
//
//  Fan art behind the Sports Hub's heroes and big cards, from TheSportsDB's
//  free API (key "123"; images need no key). A team is found by name — its
//  sport must match, so "Arsenal" the football club isn't confused with
//  anything else — and a competition by TheSportsDB's own id for the major
//  ones. One fan art is picked per team, stably, so a backdrop doesn't change
//  between visits.
//
//  Answers (misses too) are kept on disk — a month for a hit, a week for a
//  miss — and requests are spaced to stay inside the free tier's 30 a minute.
//  Nothing waits on artwork: every surface draws its team-colour wash first
//  and lays the picture over it when it arrives.
//

import Foundation

actor SportsArtwork {
    static let shared = SportsArtwork()

    enum Size {
        /// Behind a hero: the original (typically 1280 px wide).
        case hero
        /// Behind a card: TheSportsDB's 500 px preview.
        case card
    }

    private struct Entry: Codable {
        let url: URL?
        let fetchedAt: Date
    }

    static let apiBase = URL(string: "https://www.thesportsdb.com/api/v1/json/123")!
    private static let hitLifetime: TimeInterval = 30 * 86400
    private static let missLifetime: TimeInterval = 7 * 86400
    private static let spacing: Duration = .milliseconds(2100)

    /// TheSportsDB ids for the competitions the hub headlines most.
    static let leagueIds: [String: String] = [
        "espn:soccer/eng.1": "4328", "espn:soccer/esp.1": "4335", "espn:soccer/ger.1": "4331",
        "espn:soccer/ita.1": "4332", "espn:soccer/fra.1": "4334", "espn:soccer/uefa.champions": "4480",
        "espn:soccer/uefa.europa": "4481", "espn:soccer/eng.fa": "4482", "espn:soccer/eng.league_cup": "4570",
        "espn:football/nfl": "4391", "espn:basketball/nba": "4387", "espn:racing/f1": "4370", "espn:mma/ufc": "4443"
    ]

    /// ESPN's sport → TheSportsDB's `strSport`.
    static let sportNames: [String: String] = [
        "soccer": "Soccer", "football": "American Football", "basketball": "Basketball",
        "hockey": "Ice Hockey", "baseball": "Baseball", "rugby": "Rugby", "australian-football": "Australian Football"
    ]

    private var entries: [String: Entry]
    /// Each cache key owns its request until it has resolved. A backdrop can be
    /// requested by the hero, card rail and detail view at once; making those
    /// callers share work keeps the free API rate predictable.
    private var inFlight: [String: Task<URL?, Never>] = [:]
    /// Reservations, rather than a "last request" timestamp, mean concurrent
    /// callers are spaced too. Sleeping callers cannot all wake and issue a
    /// request together.
    private var nextRequestAt: ContinuousClock.Instant?
    private let session: URLSession
    private let fileURL: URL?

    init(session: URLSession = .shared) {
        self.session = session
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        fileURL = directory?.appendingPathComponent("SportsArtwork.json")
        let decodedEntries = fileURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = Self.prunedEntries(decodedEntries)
        if entries.count != decodedEntries.count,
           let fileURL,
           let data = try? JSONEncoder().encode(entries)
        {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// The backdrop for a fixture: the home side's fan art, else its
    /// competition's.
    func art(for fixture: SportsFixture, size: Size) async -> URL? {
        if let home = fixture.home?.team, let url = await teamArt(home) { return Self.sized(url, size) }
        return await leagueArt(fixture.leagueId).map { Self.sized($0, size) }
    }

    func teamArt(_ team: SportsTeam) async -> URL? {
        guard let sport = Self.sportNames[sport(of: team.leagueId)] else { return nil }
        return await cached("team:\(team.id)") {
            let query = [URLQueryItem(name: "t", value: team.name)]
            let response: TeamsResponse? = await self.fetch("searchteams.php", query)
            let match = response?.teams?.first { $0.strSport == sport }
            return match.flatMap { Self.pick($0.fanart, seed: team.id) }
        }
    }

    func leagueArt(_ leagueId: String) async -> URL? {
        guard let id = Self.leagueIds[leagueId] else { return nil }
        return await cached("league:\(leagueId)") {
            let response: LeaguesResponse? = await self.fetch("lookupleague.php", [URLQueryItem(name: "id", value: id)])
            return response?.leagues?.first.flatMap { Self.pick($0.fanart, seed: leagueId) }
        }
    }

    // MARK: - Cache

    private func cached(_ key: String, fetch: @escaping @Sendable () async -> URL?) async -> URL? {
        if let entry = entries[key] {
            let lifetime = entry.url == nil ? Self.missLifetime : Self.hitLifetime
            if Date().timeIntervalSince(entry.fetchedAt) < lifetime { return entry.url }
        }

        if let task = inFlight[key] { return await task.value }

        let task = Task<URL?, Never> { await fetch() }
        inFlight[key] = task
        let url = await task.value
        inFlight[key] = nil
        entries[key] = Entry(url: url, fetchedAt: Date())
        persist()
        return url
    }

    private static func prunedEntries(_ entries: [String: Entry], now: Date = Date()) -> [String: Entry] {
        entries.filter { _, entry in
            let lifetime = entry.url == nil ? Self.missLifetime : Self.hitLifetime
            return now.timeIntervalSince(entry.fetchedAt) < lifetime
        }
    }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Network

    private func fetch<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async -> T? {
        let now = ContinuousClock.now
        let requestAt = max(nextRequestAt ?? now, now)
        nextRequestAt = requestAt.advanced(by: Self.spacing)
        let wait = requestAt - now
        if wait > .zero { try? await Task.sleep(for: wait) }
        var request = URLRequest(url: Self.apiBase.appending(path: path).appending(queryItems: query))
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Helpers

    private func sport(of leagueId: String) -> String {
        let afterPrefix = leagueId.split(separator: ":", maxSplits: 1).last ?? Substring(leagueId)
        return String(afterPrefix.split(separator: "/", maxSplits: 1).first ?? afterPrefix)
    }

    /// One of the fan arts, the same one every time for the same seed.
    static func pick(_ candidates: [String?], seed: String) -> URL? {
        let urls = candidates.compactMap { $0.flatMap(URL.init(string:)) }
        guard !urls.isEmpty else { return nil }
        let index = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF } % urls.count
        return urls[index]
    }

    static func sized(_ url: URL, _ size: Size) -> URL {
        size == .card ? url.appending(path: "medium") : url
    }

    // MARK: - DTOs

    private struct TeamsResponse: Decodable {
        let teams: [Team]?
    }

    private struct Team: Decodable {
        let strSport: String?
        let strFanart1: String?
        let strFanart2: String?
        let strFanart3: String?
        let strFanart4: String?

        var fanart: [String?] {
            [strFanart1, strFanart2, strFanart3, strFanart4]
        }
    }

    private struct LeaguesResponse: Decodable {
        let leagues: [League]?
    }

    private struct League: Decodable {
        let strFanart1: String?
        let strFanart2: String?
        let strFanart3: String?
        let strFanart4: String?

        var fanart: [String?] {
            [strFanart1, strFanart2, strFanart3, strFanart4]
        }
    }
}

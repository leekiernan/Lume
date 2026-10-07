import Foundation

/// Plain guide/catalog values: discovery never holds background SwiftData rows.
nonisolated struct LiveTVHubChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let logoURL: String?
    let epgID: String?
    let isFavorite: Bool
    var catchupDays: Int = 0
}

nonisolated struct LiveTVHubProgramme: Identifiable, Hashable {
    let id: String
    let channel: LiveTVHubChannel
    let title: String
    let start: Date
    let end: Date
    let artworkURL: String?
    let overview: String
    let candidateID: String?
    let rank: Int

    func isLive(at now: Date) -> Bool {
        start <= now && now < end
    }

    func progress(at now: Date) -> Double {
        guard end > start else { return 0 }
        return min(max(now.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
    }
}

/// Conservative title intersection, not a fuzzy search over the whole guide.
/// Ambiguous remakes/movie-vs-series matches are misses, not wrong artwork.
nonisolated struct LiveTVTitleIndex {
    private let entries: [String: [Int]]
    private let titles: [TMDBListEntry]

    init(titles: [TMDBListEntry]) {
        self.titles = titles
        var entries: [String: [Int]] = [:]
        for (index, title) in titles.enumerated() {
            for key in Set([title.title, title.originalTitle ?? ""].map(Self.key)).filter({ !$0.isEmpty }) {
                entries[key, default: []].append(index)
            }
        }
        self.entries = entries
    }

    static func key(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    func match(title: String, year: String?, category: String?) -> (title: TMDBListEntry, rank: Int)? {
        let embeddedYear = title.range(of: #"\(\d{4}\)\s*$"#, options: .regularExpression)
            .map { String(title[$0].filter(\.isNumber)) }
        let year = year ?? embeddedYear
        let cleaned = title.replacingOccurrences(of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression)
        let exact = Self.key(cleaned)
        var indices = entries[exact] ?? []
        // XMLTV often places episode copy after the series title. Only an exact
        // series prefix is allowed, never a generic substring such as "Office".
        if indices.isEmpty, let prefix = cleaned.split(separator: ":", maxSplits: 1).first {
            let key = Self.key(String(prefix))
            if key.count >= 4 { indices = (entries[key] ?? []).filter { titles[$0].mediaType == .series } }
        }
        let category = category?.lowercased() ?? ""
        let movieOnly = category.contains("movie") || category.contains("film")
        indices = indices.filter {
            let candidate = titles[$0]
            if movieOnly, candidate.mediaType != .movie { return false }
            if let year, candidate.mediaType == .movie, candidate.releaseYear != year { return false }
            return exact.count >= 4 || year != nil
        }
        let identities = Set(indices.map { "\(titles[$0].mediaType)-\(titles[$0].id)" })
        guard identities.count == 1, let index = indices.first else { return nil }
        return (titles[index], index)
    }
}

nonisolated enum LiveTVHubPolicy {
    static let horizon: TimeInterval = 24 * 3600
    static let railLimit = 20

    static func discovery(_ programmes: [LiveTVHubProgramme], now: Date, liveOnly: Bool) -> [LiveTVHubProgramme] {
        let eligible = programmes.filter { $0.end > now && (liveOnly ? $0.isLive(at: now) : $0.start > now) }
            .sorted {
                if liveOnly, $0.rank != $1.rank { return $0.rank < $1.rank }
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.channel.isFavorite != $1.channel.isFavorite { return $0.channel.isFavorite }
                return $0.channel.id < $1.channel.id
            }
        var seen: Set<String> = []
        return Array(eligible.filter { seen.insert($0.candidateID ?? $0.id).inserted }.prefix(railLimit))
    }
}

/// Bounded per-title airings survive local clock rollover without another
/// guide scan. Duplicate channel versions do not crowd out later episodes.
nonisolated struct LiveTVHubAiringSelection {
    private var buckets: [String: [LiveTVHubProgramme]] = [:]

    var programmes: [LiveTVHubProgramme] {
        buckets.values.flatMap(\.self)
    }

    mutating func offer(_ programme: LiveTVHubProgramme, now: Date) {
        guard programme.end > now, programme.start < now.addingTimeInterval(LiveTVHubPolicy.horizon) else { return }
        let live = programme.isLive(at: now)
        let key = "\(programme.candidateID ?? programme.id)-\(live ? "live" : "upcoming")"
        var bucket = buckets[key] ?? []
        if let duplicate = bucket.firstIndex(where: { $0.start == programme.start }) {
            let previous = bucket[duplicate]
            guard programme.channel.isFavorite && !previous.channel.isFavorite
                || (programme.channel.isFavorite == previous.channel.isFavorite && programme.channel.id < previous.channel.id) else { return }
            bucket[duplicate] = programme
        } else {
            bucket.append(programme)
        }
        bucket.sort { $0.start < $1.start }
        buckets[key] = Array(bucket.prefix(live ? 1 : 4))
    }
}

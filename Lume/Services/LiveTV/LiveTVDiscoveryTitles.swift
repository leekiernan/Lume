import Foundation

/// A small, long-lived candidate list, independent of the short-lived airings.
/// Artwork arrives in the list response: no detail/search request per EPG row.
actor LiveTVDiscoveryTitles {
    static let shared = LiveTVDiscoveryTitles()
    private var cached: [String: (date: Date, titles: [TMDBListEntry])] = [:]
    private var pending: [String: Task<[TMDBListEntry], Error>] = [:]

    func titles(client: TMDBClient = .shared, now: Date = Date()) async throws -> [TMDBListEntry] {
        guard client.isConfigured else { return [] }
        let key = TMDBClient.preferredLanguageCode()
        if let entry = cached[key], now.timeIntervalSince(entry.date) < 24 * 3600 { return entry.titles }
        if let task = pending[key] { return try await task.value }
        let task = Task {
            async let movies = client.listEntries(apiPath: "movie/top_rated", media: .movie)
            async let series = client.listEntries(apiPath: "tv/top_rated", media: .series)
            let lists = try await (movies, series)
            // Comparable endpoint ranks alternate, so movie candidates don't
            // automatically outrank every series candidate in a mixed hero.
            return (0 ..< max(lists.0.count, lists.1.count)).flatMap { index in
                [lists.0.indices.contains(index) ? lists.0[index] : nil,
                 lists.1.indices.contains(index) ? lists.1[index] : nil].compactMap(\.self)
            }
        }
        pending[key] = task
        defer { pending[key] = nil }
        do {
            let titles = try await task.value
            cached[key] = (now, titles)
            return titles
        } catch {
            // A transient failure doesn't blank an already-resolved hub.
            if let previous = cached[key] { return previous.titles }
            throw error
        }
    }
}

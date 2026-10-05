import Foundation

/// The two trackers share completion precedence, but still decode and park
/// their own provider-specific history. Returns true only for a new watched
/// mark; a later rewatch can advance recency without incrementing that count.
nonisolated enum TrackerEpisodeHistory {
    static func applyCompletion(_ date: Date?, to episode: Episode, profileID: UUID?) -> Bool {
        guard WatchHistoryClears.shared.allows(date, for: episode.id, profileID: profileID) else { return false }
        if episode.isWatched {
            if let date, date > (episode.lastWatchedDate ?? .distantPast) { episode.lastWatchedDate = date }
            return false
        }
        if let local = episode.lastWatchedDate, (date ?? .distantPast) <= local { return false }
        episode.isWatched = true
        episode.watchProgress = Double(episode.durationSecs ?? 0)
        if let date { episode.lastWatchedDate = date }
        return true
    }
}

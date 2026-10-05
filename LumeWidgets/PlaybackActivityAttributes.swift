import Foundation

/// Presentation only: the player's session machine still owns playback.
nonisolated enum PlaybackActivityStatus: String, Codable, Hashable {
    case loading, playing, paused, buffering, unavailable

    var advancesProgress: Bool {
        self == .playing
    }
}

/// A short lease, not the title's duration. A killed process cannot report its
/// final state, so the widget must stop claiming playback when updates cease.
nonisolated enum PlaybackActivityFreshness {
    static let renewalInterval: TimeInterval = 15
    static let lifetime: TimeInterval = 45

    static func deadline(now: Date, windowEnd: Date?) -> Date {
        let lease = now.addingTimeInterval(lifetime)
        return windowEnd.map { min($0, lease) } ?? lease
    }

    static func needsRenewal(lastUpdate: Date?, now: Date) -> Bool {
        guard let lastUpdate else { return true }
        return now < lastUpdate || now.timeIntervalSince(lastUpdate) >= renewalInterval
    }

    static func presentation(
        status: PlaybackActivityStatus, isStale: Bool, freshUntil: Date?, now: Date
    ) -> PlaybackActivityStatus {
        if isStale || freshUntil.map({ $0 <= now }) == true { return .unavailable }
        return status
    }
}

#if os(iOS)
    import ActivityKit

    /// Shared between the app (which starts/updates the activity) and the
    /// LumeWidgets extension (which renders it). Everything that can change
    /// while the player stays open — channel surf, next episode, programme
    /// boundary — lives in the content state, so one activity spans the whole
    /// player session. ActivityKit caps attributes + state at 4 KB, so artwork
    /// travels as a file in the app-group container instead of inline data.
    nonisolated struct PlaybackActivityAttributes: ActivityAttributes {
        nonisolated struct ContentState: Codable, Hashable {
            /// Channel name for live TV, movie / series name for VOD.
            var title: String
            /// Episode marker ("S1 E4 · …") or release date; nil for live TV.
            var subtitle: String?
            var isLive: Bool
            var isPaused: Bool
            /// Optional so activities created before this schema still decode.
            var status: PlaybackActivityStatus?
            var freshUntil: Date?
            /// Artwork copy in the app-group container, if one could be written.
            var artworkFileName: String?
            /// The EPG programme currently airing (live TV only).
            var programmeTitle: String?
            /// Live: the current programme's air window. VOD: a synthetic
            /// window (`now - elapsed … now + remaining`) so the progress bar
            /// ticks on its own between ActivityKit updates.
            var windowStart: Date?
            var windowEnd: Date?
            /// VOD position at the time of the update, for the frozen bar
            /// while paused. Live playback leaves both nil.
            var elapsed: TimeInterval?
            var duration: TimeInterval?
            /// The EPG "up next" programme (live TV only).
            var nextTitle: String?
            var nextStart: Date?

            func presentation(isStale: Bool, now: Date = .now) -> PlaybackActivityStatus {
                PlaybackActivityFreshness.presentation(
                    status: status ?? (isPaused ? .paused : .playing),
                    isStale: isStale, freshUntil: freshUntil, now: now
                )
            }
        }

        /// One activity per player session; the id only disambiguates requests.
        var sessionID: String
    }

    /// The app writes a downscaled artwork copy here; the widget extension
    /// reads it back. Both sides resolve the same app-group container.
    nonisolated enum PlaybackActivityArtworkStore {
        static let appGroupID = "group.com.leekiernan.lume"
        static let directoryName = "LiveActivityArtwork"

        static var directoryURL: URL? {
            FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
                .appendingPathComponent(directoryName, isDirectory: true)
        }

        static func url(for fileName: String) -> URL? {
            directoryURL?.appendingPathComponent(fileName)
        }
    }
#endif

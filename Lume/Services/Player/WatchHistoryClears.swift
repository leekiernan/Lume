import Foundation

/// An explicit unwatch has no `lastWatchedDate`, but must still beat older
/// tracker history (especially Trakt's paused playback, which history removal
/// does not delete). Keep that intent separately from rail-visible recency.
/// Profile-scoped and device-local; CloudKit clears use `ContentClearLedger`.
final nonisolated class WatchHistoryClears: @unchecked Sendable {
    static let shared = WatchHistoryClears()
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ id: String, at date: Date = .now, profileID: UUID? = ActiveProfileStore.current) {
        lock.withLock {
            let key = storageKey(profileID)
            var dates = defaults.dictionary(forKey: key) ?? [:]
            dates[id] = date.timeIntervalSince1970
            defaults.set(dates, forKey: key)
        }
    }

    /// Undated remote history cannot override an explicit reset. A genuinely
    /// newer play elsewhere can, without dropping the guard against old data.
    func allows(_ date: Date?, for id: String, profileID: UUID? = ActiveProfileStore.current) -> Bool {
        lock.withLock {
            guard let cleared = defaults.dictionary(forKey: storageKey(profileID))?[id] as? Double else { return true }
            return (date ?? .distantPast).timeIntervalSince1970 > cleared
        }
    }

    func purge(profileID: UUID) {
        lock.withLock { defaults.removeObject(forKey: storageKey(profileID)) }
    }

    private func storageKey(_ profileID: UUID?) -> String {
        "watchHistory.clears.v1.\((profileID ?? UserProfile.defaultProfileID).uuidString)"
    }
}

import Foundation

/// Device-local fingerprint persistence only. Each source retains its namespace,
/// fingerprint algorithm and successful-import/coverage guards.
nonisolated struct PlaylistDigestStore {
    let namespace: String

    func key(playlistId: UUID) -> String {
        "\(namespace).\(playlistId.uuidString)"
    }

    func digest(playlistId: UUID, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(playlistId: playlistId))
    }

    func store(_ digest: String, playlistId: UUID, defaults: UserDefaults = .standard) {
        defaults.set(digest, forKey: key(playlistId: playlistId))
    }

    func remove(playlistId: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(playlistId: playlistId))
    }
}

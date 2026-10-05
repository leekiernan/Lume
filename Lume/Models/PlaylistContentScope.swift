import Foundation

nonisolated enum PlaylistContentScope {
    static func prefix(for id: UUID) -> String {
        CatalogID.playlistPrefix(id)
    }
}

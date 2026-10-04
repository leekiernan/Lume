import Foundation

nonisolated enum PlaylistContentScope {
    static func prefix(for id: UUID) -> String {
        "\(id.uuidString)-"
    }
}

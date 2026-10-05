import Foundation

/// Restrict first, then prefer the active playlist without changing source order.
nonisolated enum CatalogMatchSelection {
    static func preferred<Item: CategorizedContent & Identifiable>(
        in items: [Item], restriction: ContentRestriction, playlistPrefix: String?
    ) -> Item? where Item.ID == String {
        let visible = items.excludingRestricted(restriction)
        guard let playlistPrefix else { return visible.first }
        return visible.first { $0.id.hasPrefix(playlistPrefix) } ?? visible.first
    }
}

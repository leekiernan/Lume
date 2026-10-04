//
//  PlaylistOwner.swift
//  Lume
//
//  Resolves the playlist that owns a catalog row from the row's id. Every synced
//  id is written as "<playlist UUID>-<kind>-<provider id>" by `ContentSyncManager`,
//  so player lookups can use one indexed fetch rather than walking every installed
//  playlist. Scene callers already holding query results use the array overload,
//  with their legacy fallback selected explicitly instead of duplicated in views.
//

import Foundation
import SwiftData

nonisolated enum PlaylistOwner {
    enum Fallback {
        case none
        /// Preserve input order for legacy orphan/non-prefixed content and
        /// the TV episode overlay's missing-series case. This is neither the
        /// oldest nor active playlist, and does not prove ownership.
        case firstAvailable
    }

    /// Array-backed callers already hold their scene's query results. Preserve
    /// their historical UUID prefix spelling, and make fallback an explicit
    /// opt-in. Player lookups below remain strictly indexed, with no fallback.
    @MainActor
    static func playlist(forContentID contentID: String?, in playlists: [Playlist], fallback: Fallback = .none) -> Playlist? {
        if let contentID, let owner = playlists.first(where: { contentID.hasPrefix($0.id.uuidString) }) { return owner }
        switch fallback {
        case .none: return nil
        case .firstAvailable: return playlists.first
        }
    }

    /// The number of characters a canonical `UUID.uuidString` occupies. Ids are
    /// built from that exact spelling, so the owner's UUID is the leading slice.
    private static let uuidLength = 36

    /// The playlist whose UUID prefixes `id`, or `nil` when `id` names no
    /// installed playlist. Never a fallback to some other playlist: callers
    /// build a `PlayableMedia` from the answer, so a guess would play the row
    /// with the wrong provider's credentials on a multi-playlist install.
    static func playlist(forPrefixedID id: String, in context: ModelContext) -> Playlist? {
        guard let owner = declaredOwner(of: id) else { return nil }
        return playlist(withID: owner, in: context)
    }

    private static func playlist(withID id: UUID, in context: ModelContext) -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The UUID `id` starts with, or `nil` when it doesn't start with one.
    /// Round-tripped through `uuidString` on purpose: the prefix scan this
    /// replaced matched that canonical spelling verbatim, and `UUID(uuidString:)`
    /// also accepts spellings it would have missed.
    private static func declaredOwner(of id: String) -> UUID? {
        guard id.count > uuidLength else { return nil }
        let candidate = String(id.prefix(uuidLength))
        guard let uuid = UUID(uuidString: candidate), uuid.uuidString == candidate else { return nil }
        return uuid
    }
}

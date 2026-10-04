import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LiveChannelRailTests {
    @Test func `picker rail matches browse composition and user ordering across profile scopes`() throws {
        try OnDiskCatalogStore.withContext { context in
            let mine = Playlist(name: "Mine", serverURL: "https://a.example", username: "u", password: "p")
            let other = Playlist(name: "Other", serverURL: "https://b.example", username: "u", password: "p")
            context.insert(mine)
            context.insert(other)
            let late = Lume.Category(apiId: "1", name: "Late", parentId: 0, type: .live, playlist: mine)
            late.sortOrder = 10
            let first = Lume.Category(apiId: "2", name: "First", parentId: 0, type: .live, playlist: mine)
            first.sortOrder = 20
            first.customOrder = 0
            let locked = Lume.Category(apiId: "3", name: "Locked", parentId: 0, type: .live, playlist: mine)
            locked.sortOrder = 30
            let hidden = Lume.Category(apiId: "4", name: "Hidden", parentId: 0, type: .live, playlist: mine)
            hidden.isHidden = true
            let foreign = Lume.Category(apiId: "1", name: "Foreign", parentId: 0, type: .live, playlist: other)
            let movie = Lume.Category(apiId: "5", name: "Movie", parentId: 0, type: .vod, playlist: mine)
            for category in [late, first, locked, hidden, foreign, movie] {
                context.insert(category)
            }
            let prefix = "\(mine.id.uuidString)-"
            let channel = LiveStream(id: "\(prefix)live-1", streamId: 1, name: "Locked", categoryId: locked.id)
            channel.isFavorite = true
            channel.lastWatchedDate = Date()
            context.insert(channel)
            try context.save()

            let child = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked.id])
            let childRail = LiveChannelQuery.rail(in: context, playlistPrefix: prefix, restriction: child)
            #expect(childRail == [.category(first), .category(late)])
            let parent = ContentRestriction(isActive: false, restrictedCategoryIDs: [locked.id])
            let parentRail = LiveChannelQuery.rail(in: context, playlistPrefix: prefix, restriction: parent)
            #expect(parentRail == [.favorites, .recentlyWatched, .category(first), .category(late), .category(locked)])
            let memo = LiveTVCategoryMemo()
            let categorySections = memo.sections(categories: [late, first, locked, hidden, foreign, movie], playlistPrefix: prefix, sort: .playlist, restriction: parent)
            #expect(parentRail == LiveTVSection.resolve(playlistPrefix: prefix, categories: categorySections, hasFavorites: true, hasRecentlyWatched: true))
            #expect(LiveChannelQuery.rail(in: context, playlistPrefix: "\(other.id.uuidString)-", restriction: parent) == [.category(foreign)])
            #expect(LiveChannelQuery.rail(in: context, playlistPrefix: "", restriction: parent).isEmpty)
        }
    }

    @Test func `picker virtual sections survive missing categories but not hidden channels`() throws {
        try OnDiskCatalogStore.withContext { context in
            let channel = LiveStream(id: "mine-live-1", streamId: 1, name: "Uncategorized", categoryId: nil)
            channel.isFavorite = true
            channel.lastWatchedDate = Date()
            context.insert(channel)
            try context.save()
            let restriction = ContentRestriction(hiddenCategoryIDs: ["missing-category"])
            #expect(LiveChannelQuery.rail(in: context, playlistPrefix: "mine-", restriction: restriction) == [.favorites, .recentlyWatched])
            channel.isHidden = true
            try context.save()
            #expect(LiveChannelQuery.rail(in: context, playlistPrefix: "mine-", restriction: restriction).isEmpty)
        }
    }
}

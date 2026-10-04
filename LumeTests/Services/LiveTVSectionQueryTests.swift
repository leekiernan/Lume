import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LiveTVSectionQueryTests {
    @Test func `live categories isolate the playlist and profile visibility in SQLite`() throws {
        try OnDiskCatalogStore.withContext { context in
            let mine = Playlist(name: "Mine", serverURL: "https://a.example", username: "u", password: "p")
            let other = Playlist(name: "Other", serverURL: "https://b.example", username: "u", password: "p")
            context.insert(mine)
            context.insert(other)
            let visible = Lume.Category(apiId: "1", name: "News", parentId: 0, type: .live, playlist: mine)
            let restricted = Lume.Category(apiId: "2", name: "Restricted", parentId: 0, type: .live, playlist: mine)
            let hidden = Lume.Category(apiId: "3", name: "Hidden", parentId: 0, type: .live, playlist: mine)
            hidden.isHidden = true
            let foreign = Lume.Category(apiId: "1", name: "Foreign", parentId: 0, type: .live, playlist: other)
            let movie = Lume.Category(apiId: "4", name: "Movies", parentId: 0, type: .vod, playlist: mine)
            for row in [visible, restricted, hidden, foreign, movie] {
                context.insert(row)
            }
            try context.save()
            let prefix = "\(mine.id.uuidString)-"
            let child = ContentRestriction(isActive: true, restrictedCategoryIDs: [restricted.id])
            #expect(try categories(in: context, prefix: prefix, restriction: child).map(\.id) == [visible.id])
            let parent = ContentRestriction(isActive: false, restrictedCategoryIDs: [restricted.id])
            #expect(try Set(categories(in: context, prefix: prefix, restriction: parent).map(\.id)) == [visible.id, restricted.id])
            let hiddenByProfile = ContentRestriction(hiddenCategoryIDs: [visible.id, restricted.id])
            #expect(try categories(in: context, prefix: prefix, restriction: hiddenByProfile).isEmpty)
            #expect(try categories(in: context, prefix: "\(other.id.uuidString)-", restriction: child).map(\.id) == [foreign.id])
        }
    }

    @Test func `empty scoped categories retain visible uncategorized favorites and recents`() throws {
        try OnDiskCatalogStore.withContext { context in
            let mine = Playlist(name: "Mine", serverURL: "https://a.example", username: "u", password: "p")
            context.insert(mine)
            let excluded = Lume.Category(apiId: "1", name: "Hidden", parentId: 0, type: .live, playlist: mine)
            context.insert(excluded)
            let prefix = "\(mine.id.uuidString)-"
            let favorite = LiveStream(id: "\(prefix)live-1", streamId: 1, name: "Favorite", categoryId: nil)
            favorite.isFavorite = true
            favorite.lastWatchedDate = Date(timeIntervalSince1970: 1)
            context.insert(favorite)
            let locked = LiveStream(id: "\(prefix)live-2", streamId: 2, name: "Locked", categoryId: excluded.id)
            locked.isFavorite = true
            context.insert(locked)
            try context.save()
            let restriction = ContentRestriction(hiddenCategoryIDs: [excluded.id])
            let rows = try categories(in: context, prefix: prefix, restriction: restriction)
            #expect(rows.isEmpty)
            let favoriteProbe = LiveChannelQuery.favoritesProbe(playlistPrefix: prefix, restriction: restriction)
            let recentProbe = LiveChannelQuery.recentlyWatchedProbe(playlistPrefix: prefix, restriction: restriction)
            #expect(favoriteProbe.fetchLimit == 1 && recentProbe.fetchLimit == 1)
            #expect(favoriteProbe.sortBy.isEmpty && recentProbe.sortBy.isEmpty)
            let sections = try LiveTVSection.resolve(
                playlistPrefix: prefix, categories: rows.map(LiveTVSection.category),
                hasFavorites: !context.fetch(favoriteProbe).isEmpty,
                hasRecentlyWatched: !context.fetch(recentProbe).isEmpty
            )
            #expect(sections == [.favorites, .recentlyWatched])
        }
    }

    @Test func `virtual sections precede ordered categories and no playlist cannot leak probe results`() {
        let playlist = Playlist(name: "Mine", serverURL: "https://a.example", username: "u", password: "p")
        let category = Lume.Category(apiId: "1", name: "News", parentId: 0, type: .live, playlist: playlist)
        let rows: [LiveTVSection] = [.category(category)]
        #expect(LiveTVSection.resolve(playlistPrefix: "mine-", categories: rows, hasFavorites: true, hasRecentlyWatched: true)
            == [.favorites, .recentlyWatched, .category(category)])
        #expect(LiveTVSection.resolve(playlistPrefix: "", categories: [], hasFavorites: true, hasRecentlyWatched: true).isEmpty)
        #expect(LiveTVSection.resolve(playlistPrefix: "mine-", categories: [], hasFavorites: false, hasRecentlyWatched: false).isEmpty)
    }

    private func categories(in context: ModelContext, prefix: String, restriction: ContentRestriction) throws -> [Lume.Category] {
        try context.fetch(LibraryCategoryQuery.descriptor(type: .live, playlistPrefix: prefix, excludedCategoryIDs: restriction.excludedCategoryIDs))
    }

    @Test func `empty state detects stored hidden channels with a bounded playlist scoped probe`() throws {
        try OnDiskCatalogStore.withContext { context in
            let hidden = LiveStream(id: "mine-live-1", streamId: 1, name: "Hidden", categoryId: "mine-live-hidden")
            hidden.isHidden = true
            context.insert(hidden)
            context.insert(LiveStream(id: "other-live-1", streamId: 2, name: "Other", categoryId: nil))
            try context.save()
            let probe = LiveChannelQuery.excludedChannelsProbe(playlistPrefix: "mine-", restriction: ContentRestriction())
            #expect(probe.fetchLimit == 1 && probe.sortBy.isEmpty)
            #expect(try context.fetch(probe).map(\.id) == [hidden.id])
            #expect(try context.fetch(LiveChannelQuery.excludedChannelsProbe(playlistPrefix: "other-", restriction: ContentRestriction())).isEmpty)
            #expect(try context.fetch(LiveChannelQuery.excludedChannelsProbe(playlistPrefix: "", restriction: ContentRestriction())).isEmpty)
            hidden.isHidden = false
            try context.save()
            #expect(try context.fetch(probe).isEmpty)
            let child = ContentRestriction(isActive: true, restrictedCategoryIDs: ["mine-live-hidden"])
            #expect(try context.fetch(LiveChannelQuery.excludedChannelsProbe(playlistPrefix: "mine-", restriction: child)).map(\.id) == [hidden.id])
        }
    }
}

//
//  LibraryCategoryQueryTests.swift
//  LumeTests
//
//  The Movies/Series pages list the active playlist's visible categories of one
//  type. That selection used to happen in Swift over every playlist's
//  categories on each body pass; it is a SQL predicate now, so it runs against
//  a real store (`OnDiskCatalogStore`) to prove SQLite can render it.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LibraryCategoryQueryTests {
    @Test func `selects one type in the active playlist, minus excluded and hidden categories`() throws {
        try OnDiskCatalogStore.withContext { context in
            let mine = Playlist(name: "Mine", serverURL: "http://a.example", username: "u", password: "p")
            let theirs = Playlist(name: "Theirs", serverURL: "http://b.example", username: "u", password: "p")
            context.insert(mine)
            context.insert(theirs)

            let action = Lume.Category(apiId: "1", name: "Action", parentId: 0, type: .vod, playlist: mine)
            let drama = Lume.Category(apiId: "2", name: "Drama", parentId: 0, type: .vod, playlist: mine)
            let locked = Lume.Category(apiId: "3", name: "Locked", parentId: 0, type: .vod, playlist: mine)
            let hidden = Lume.Category(apiId: "4", name: "Hidden", parentId: 0, type: .vod, playlist: mine)
            hidden.isHidden = true
            let shows = Lume.Category(apiId: "5", name: "Shows", parentId: 0, type: .series, playlist: mine)
            let elsewhere = Lume.Category(apiId: "1", name: "Action", parentId: 0, type: .vod, playlist: theirs)
            for category in [action, drama, locked, hidden, shows, elsewhere] {
                context.insert(category)
            }
            try context.save()

            let prefix = "\(mine.id.uuidString)-"
            let movies = try context.fetch(LibraryCategoryQuery.descriptor(
                type: .vod, playlistPrefix: prefix, excludedCategoryIDs: [locked.id]
            ))
            #expect(Set(movies.map(\.id)) == [action.id, drama.id])

            let unrestricted = try context.fetch(LibraryCategoryQuery.descriptor(
                type: .vod, playlistPrefix: prefix, excludedCategoryIDs: []
            ))
            #expect(Set(unrestricted.map(\.id)) == [action.id, drama.id, locked.id])

            let series = try context.fetch(LibraryCategoryQuery.descriptor(
                type: .series, playlistPrefix: prefix, excludedCategoryIDs: []
            ))
            #expect(series.map(\.id) == [shows.id])
        }
    }
}

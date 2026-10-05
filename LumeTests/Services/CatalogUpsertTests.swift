import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct CatalogUpsertTests {
    @Test func `lazy episode materialization is additive and duplicate safe`() throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let series = Series(id: "series", seriesId: 1, name: "Show")
        context.insert(series)
        let parsed = ParsedEpisode(id: "episode", episodeId: "1", title: "Pilot", containerExtension: "mkv",
                                   seasonNum: 1, episodeNum: 1, added: nil, directSource: nil, durationSecs: nil,
                                   movieImage: nil, rating: nil, airDate: nil, plot: nil)
        series.insertEpisodes([parsed, parsed], into: context)
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 1)
        let stored = try #require(series.episodes.first)
        stored.watchProgress = 90
        series.insertEpisodes([parsed], into: context)
        #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 1)
        #expect(stored.watchProgress == 90)
    }

    @Test func `historical catalog keys retain exact bytes`() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        let prefix = id.uuidString
        #expect(PlaylistContentScope.prefix(for: id) == "\(prefix)-")
        #expect(CatalogID.category(id, type: "vod", key: "genre-name") == "\(prefix)-vod-genre-name")
        #expect(CatalogID.category(nil, type: "series", key: "001") == "unknown-series-001")
        #expect(CatalogID.content(id, kind: .movie, key: 42) == "\(prefix)-movie-42")
        #expect(CatalogID.content(id, kind: .series, key: "abc") == "\(prefix)-series-abc")
        #expect(CatalogID.content(id, kind: .live, key: -4) == "\(prefix)-live--4")
        #expect(CatalogID.episode(ownerID: "\(prefix)-series-42", key: "007") == "\(prefix)-series-42-episode-007")
        for infix in ["jellyfin", "emby", "plex", "vod", "series", "live"] {
            #expect(CatalogID.prefix(id, infix: infix) == "\(prefix)-\(infix)-")
            #expect(CatalogID.episode(prefix: CatalogID.prefix(id, infix: infix), key: "007") == "\(prefix)-\(infix)-episode-007")
        }
    }

    @Test func `duplicate identities reuse the row and unchanged applies leave the context clean`() throws {
        try OnDiskCatalogStore.withContext { context in
            context.autosaveEnabled = false
            let movie = Movie(id: "movie-1", streamId: 1, name: "Original")
            movie.isFavorite = true
            movie.watchProgress = 123
            movie.posterPath = "/stored.jpg"
            context.insert(movie)
            context.insert(Movie(id: "unrelated", streamId: 2, name: "Other"))
            try context.save()
            let originalID = movie.persistentModelID
            let identities: [String?] = ["movie-1", "new", "new", nil]
            var creates = 0
            let seen = try CatalogUpsert.batch(identities, context: context,
                                               identity: { $0 }, create: { _, id in
                                                   creates += 1
                                                   return Movie(id: id, streamId: 3, name: "New")
                                               }, apply: { _, _ in })
            #expect(creates == 1)
            #expect(Set(seen) == ["movie-1", "new"])
            try context.save()
            #expect(movie.persistentModelID == originalID)
            #expect(movie.isFavorite && movie.watchProgress == 123 && movie.posterPath == "/stored.jpg")
            let loaded = try CatalogUpsert.lookup(Movie.self, ids: ["movie-1", "new"], context: context)
            #expect(Set(loaded.keys) == Set(seen))
            _ = try CatalogUpsert.batch(identities, context: context,
                                        identity: { $0 }, create: { _, id in Movie(id: id, streamId: 0, name: "Unexpected") },
                                        apply: { _, row in if row.name == "" { row.name = "Changed" } })
            #expect(!context.hasChanges)
        }
    }

    @Test func `concrete descriptors keep all row kinds and episode reparenting separate`() throws {
        try OnDiskCatalogStore.withContext { context in
            let movie = Movie(id: "shared", streamId: 1, name: "Movie")
            let show = Series(id: "shared", seriesId: 1, name: "Show")
            let old = Series(id: "old", seriesId: 2, name: "Old")
            let live = LiveStream(id: "shared", streamId: 1, name: "Channel")
            let episode = Episode(id: "shared", episodeId: "1", title: "Pilot", containerExtension: "mkv", seasonNum: 1, episodeNum: 1)
            context.insert(movie)
            context.insert(show)
            context.insert(old)
            context.insert(live)
            context.insert(episode)
            episode.series = old
            episode.watchProgress = 99
            try context.save()
            #expect(try CatalogUpsert.lookup(Movie.self, ids: ["shared"], context: context)["shared"] === movie)
            #expect(try CatalogUpsert.lookup(Series.self, ids: ["shared"], context: context)["shared"] === show)
            #expect(try CatalogUpsert.lookup(LiveStream.self, ids: ["shared"], context: context)["shared"] === live)
            #expect(try CatalogUpsert.lookup(Episode.self, ids: ["shared"], context: context)["shared"] === episode)
            CatalogUpsert.attach(episode, to: show)
            try context.save()
            context.delete(old)
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<Episode>()) == 1)
            #expect(episode.watchProgress == 99 && episode.series?.id == "shared")
        }
    }
}

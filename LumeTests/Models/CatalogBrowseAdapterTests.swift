import Foundation
@testable import Lume
import SwiftData
import SwiftUI
import Testing

@MainActor
struct CatalogBrowseAdapterTests {
    @Test func `category adapters filter before paging and retain provider order and name tie breaks in SQLite`() throws {
        try OnDiskCatalogStore.withContext { context in
            for (index, name, category) in [(1, "Z", "other"), (3, "Z", "wanted"), (2, "B", "wanted"), (2, "A", "wanted")] {
                let id = "\(category)-\(name)-\(index)"
                let movie = Movie(id: id, streamId: index, name: name)
                movie.num = index
                movie.categoryId = category
                let series = Series(id: id, seriesId: index, name: name)
                series.num = index
                series.categoryId = category
                context.insert(movie)
                context.insert(series)
            }
            try context.save()
            let movies = try MovieCatalog.categoryPage(in: context, id: "wanted", offset: 0, limit: 2)
            let series = try SeriesCatalog.categoryPage(in: context, id: "wanted", offset: 0, limit: 2)
            #expect(movies.map(\.name) == ["A", "B"])
            #expect(series.map(\.name) == ["A", "B"])
            #expect(try MovieCatalog.categoryPage(in: context, id: "wanted", offset: 2, limit: 2).map(\.name) == ["Z"])
            #expect(try SeriesCatalog.categoryPage(in: context, id: "wanted", offset: 2, limit: 2).map(\.name) == ["Z"])
        }
    }

    @Test func `genre adapters retain concrete medium playlist visibility and exact genre matching`() throws {
        try OnDiskCatalogStore.withContext { context in
            for (id, category, genre) in [("one-1", "hidden", "Drama"), ("two-2", "visible", "Drama"),
                                          ("one-3", "visible", "Melodrama"), ("one-4", "visible", "Drama, Comedy")]
            {
                let movie = Movie(id: id, streamId: 1, name: id)
                movie.categoryId = category
                movie.genre = genre
                let series = Series(id: id, seriesId: 1, name: id, genre: genre)
                series.categoryId = category
                context.insert(movie)
                context.insert(series)
            }
            try context.save()
            let request = GenrePageRequest(genre: "Drama", playlistPrefix: "one-", excludedCategoryIDs: ["hidden"], offset: 0, pageSize: 100)
            let movies = MovieCatalog.genrePage(container: context.container, request: request)
            let series = SeriesCatalog.genrePage(container: context.container, request: request)
            #expect(movies.ids.compactMap { context.model(for: $0) as? Movie }.map(\.id) == ["one-4"])
            #expect(series.ids.compactMap { context.model(for: $0) as? Series }.map(\.id) == ["one-4"])
            #expect(movies.reachedEnd && series.reachedEnd)
        }
    }

    @Test func `collection adapters exclude other playlists and hidden rows before bounded fetch`() throws {
        try OnDiskCatalogStore.withContext { context in
            for (id, category) in [("one-1", "hidden"), ("two-2", "visible"), ("one-3", "visible")] {
                let movie = Movie(id: id, streamId: 1, name: id)
                movie.categoryId = category
                movie.isFavorite = true
                let series = Series(id: id, seriesId: 1, name: id)
                series.categoryId = category
                series.isFavorite = true
                context.insert(movie)
                context.insert(series)
            }
            try context.save()
            let movies = try context.fetch(MovieCatalog.collectionDescriptor(.favorites, prefix: "one-", excluded: ["hidden"], offset: 0, limit: 1))
            let series = try context.fetch(SeriesCatalog.collectionDescriptor(.favorites, prefix: "one-", excluded: ["hidden"], offset: 0, limit: 1))
            #expect(movies.map(\.id) == ["one-3"])
            #expect(series.map(\.id) == ["one-3"])
        }
    }

    @Test func `library path bindings read and write only their own deep link stack`() {
        let router = DeepLinkRouter()
        let movies = MediaDetailNavigation.pathBinding(in: router, at: MovieCatalog.navigationPath, fallback: .constant(NavigationPath()))
        let series = MediaDetailNavigation.pathBinding(in: router, at: SeriesCatalog.navigationPath, fallback: .constant(NavigationPath()))
        movies.wrappedValue.append("movie")
        #expect(router.moviesPath.count == 1)
        #expect(router.seriesPath.isEmpty)
        series.wrappedValue.append("series")
        #expect(router.moviesPath.count == 1)
        #expect(router.seriesPath.count == 1)
        series.wrappedValue = NavigationPath()
        #expect(router.seriesPath.isEmpty)
        #expect(movies.wrappedValue.count == 1)
    }

    @Test func `hero adapters accept only their media kind and keep layout storage namespaces`() {
        let movie = Movie(id: "movie", streamId: 1, name: "Movie")
        let series = Series(id: "series", seriesId: 1, name: "Series")
        let movieHero = HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: "")
        let seriesHero = HeroItem.series(series, backdropURL: nil, logoURL: nil, overview: "")
        #expect(MovieCatalog.heroItem(movieHero) === movie)
        #expect(SeriesCatalog.heroItem(seriesHero) === series)
        #expect(MovieCatalog.heroItem(seriesHero) == nil)
        #expect(SeriesCatalog.heroItem(movieHero) == nil)
        #expect(MovieCatalog.categoryType == .vod && MovieCatalog.surface == .movies)
        #expect(SeriesCatalog.categoryType == .series && SeriesCatalog.surface == .series)
        #expect(HomeLayoutSettings.heroSectionKey(MovieCatalog.surface) == HomeLayoutSettings.heroSectionKey(.movies))
        #expect(HomeLayoutSettings.heroSectionKey(SeriesCatalog.surface) == HomeLayoutSettings.heroSectionKey(.series))
    }

    @Test func `an empty Series collection changes its split task identity when preparation finishes`() {
        let pending = SeriesCatalog.progressRequestKey(request: "watch-profile", loaded: nil, items: [], kind: .recentlyWatched)
        let prepared = SeriesCatalog.progressRequestKey(request: "watch-profile", loaded: "watch-profile", items: [], kind: .recentlyWatched)
        let oldScope = SeriesCatalog.progressRequestKey(request: "watch-profile", loaded: "old-profile", items: [], kind: .recentlyWatched)
        #expect(pending != prepared)
        #expect(oldScope != prepared)
    }

    @Test func `only Series watch collections require an episode split`() {
        let series = Series(id: "series", seriesId: 1, name: "Series")
        var progress = ContinueWatchingLoader.Result()
        progress.finished.insert(series.id)
        #expect(SeriesCatalog.splits(.continueWatching))
        #expect(SeriesCatalog.splits(.recentlyWatched))
        #expect(!SeriesCatalog.splits(.favorites))
        #expect(!MovieCatalog.splits(.continueWatching))
        #expect(SeriesCatalog.shown([series], kind: .continueWatching, progress: progress).isEmpty)
        #expect(SeriesCatalog.shown([series], kind: .recentlyWatched, progress: progress).map(\.id) == [series.id])
    }
}

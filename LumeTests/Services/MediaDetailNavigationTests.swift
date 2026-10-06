import Foundation
@testable import Lume
import SwiftUI
import Testing

@MainActor
struct MediaDetailNavigationTests {
    private final class PathBox {
        var value = NavigationPath()

        var binding: Binding<NavigationPath> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    @Test func `movie hero pushes the registered movie destination`() {
        let movie = Movie(id: "movie-1", streamId: 1, name: "Film")
        let hero = HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: "")
        var expected = NavigationPath()
        expected.append(movie)
        #expect(MediaDetailNavigation.appending(hero, to: NavigationPath()) == expected)
    }

    @Test func `series hero pushes the registered series destination`() {
        let series = Series(id: "series-1", seriesId: 1, name: "Show")
        let hero = HeroItem.series(series, backdropURL: nil, logoURL: nil, overview: "")
        var expected = NavigationPath()
        expected.append(series)
        #expect(MediaDetailNavigation.appending(hero, to: NavigationPath()) == expected)
    }

    @Test func `returning to Home retains the hero destination without retaining its view`() {
        let movie = Movie(id: "movie-1", streamId: 1, name: "Film")
        let hero = HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: "")
        let router = DeepLinkRouter()
        router.homePath = MediaDetailNavigation.appending(hero, to: router.homePath)
        let savedPath = router.homePath
        router.selectedTab = .movies
        router.selectedTab = .series
        router.selectedTab = .home
        #expect(router.homePath == savedPath)
        #expect(router.homePath.count == 1)
        #expect(router.moviesPath.isEmpty && router.seriesPath.isEmpty)
    }

    @Test func `hero navigation appends without replacing a parent collection`() {
        let movie = Movie(id: "movie-1", streamId: 1, name: "Film")
        let hero = HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: "")
        var parent = NavigationPath()
        parent.append("collection")
        var expected = parent
        expected.append(movie)
        #expect(MediaDetailNavigation.appending(hero, to: parent) == expected)
        #expect(parent.count == 1)
    }

    @Test func `all three areas restore their own router path through the shared binding`() {
        let router = DeepLinkRouter()
        let fallback = PathBox()
        fallback.value.append("preview")
        let routes: [(AppTab, ReferenceWritableKeyPath<DeepLinkRouter, NavigationPath>)] = [
            (.home, \.homePath), (.movies, MovieCatalog.navigationPath), (.series, SeriesCatalog.navigationPath)
        ]
        let movie = Movie(id: "movie-1", streamId: 1, name: "Film")
        let series = Series(id: "series-1", seriesId: 1, name: "Show")

        for (tab, path) in routes {
            let binding = MediaDetailNavigation.pathBinding(in: router, at: path, fallback: fallback.binding)
            binding.wrappedValue = MediaDetailNavigation.appending(
                .movie(movie, backdropURL: nil, logoURL: nil, overview: ""), to: binding.wrappedValue
            )
            binding.wrappedValue = MediaDetailNavigation.appending(
                .series(series, backdropURL: nil, logoURL: nil, overview: ""), to: binding.wrappedValue
            )
            let saved = binding.wrappedValue
            router.selectedTab = .search
            router.selectedTab = tab

            // Recreated view bindings still target the same persistent owner.
            let restored = MediaDetailNavigation.pathBinding(in: router, at: path, fallback: fallback.binding)
            #expect(restored.wrappedValue == saved)
            #expect(restored.wrappedValue.count == 2)
            restored.wrappedValue.removeLast()
            #expect(router[keyPath: path].count == 1)
            #expect(fallback.value.count == 1)
        }

        #expect(router.homePath.count == 1)
        #expect(router.moviesPath.count == 1)
        #expect(router.seriesPath.count == 1)
        #expect(router.sportsPath.isEmpty)
    }

    @Test func `preview navigation writes through the local fallback without a router`() {
        let fallback = PathBox()
        let binding = MediaDetailNavigation.pathBinding(in: nil, at: \.homePath, fallback: fallback.binding)
        binding.wrappedValue.append("collection")
        #expect(fallback.value.count == 1)
        #expect(MediaDetailNavigation.pathBinding(in: nil, at: \.homePath, fallback: fallback.binding).wrappedValue == fallback.value)
        binding.wrappedValue.removeLast()
        #expect(fallback.value.isEmpty)
    }
}

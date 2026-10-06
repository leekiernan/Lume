import Foundation
@testable import Lume
import SwiftUI
import Testing

@MainActor
struct HomeHeroNavigationTests {
    @Test func `movie hero pushes the registered movie destination`() {
        let movie = Movie(id: "movie-1", streamId: 1, name: "Film")
        let hero = HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: "")
        var expected = NavigationPath()
        expected.append(movie)
        #expect(HomeHeroNavigation.appending(hero, to: NavigationPath()) == expected)
    }

    @Test func `series hero pushes the registered series destination`() {
        let series = Series(id: "series-1", seriesId: 1, name: "Show")
        let hero = HeroItem.series(series, backdropURL: nil, logoURL: nil, overview: "")
        var expected = NavigationPath()
        expected.append(series)
        #expect(HomeHeroNavigation.appending(hero, to: NavigationPath()) == expected)
    }

    @Test func `returning to Home retains the hero destination without retaining its view`() {
        let movie = Movie(id: "movie-1", streamId: 1, name: "Film")
        let hero = HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: "")
        let router = DeepLinkRouter()
        router.homePath = HomeHeroNavigation.appending(hero, to: router.homePath)
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
        #expect(HomeHeroNavigation.appending(hero, to: parent) == expected)
        #expect(parent.count == 1)
    }
}

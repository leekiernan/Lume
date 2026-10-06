import Foundation
@testable import Lume
import SwiftUI
import Testing

@MainActor
struct DetailNavigationTests {
    @MainActor
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
        #expect(DetailNavigation.appending(hero, to: NavigationPath()) == expected)
    }

    @Test func `series hero pushes the registered series destination`() {
        let series = Series(id: "series-1", seriesId: 1, name: "Show")
        let hero = HeroItem.series(series, backdropURL: nil, logoURL: nil, overview: "")
        var expected = NavigationPath()
        expected.append(series)
        #expect(DetailNavigation.appending(hero, to: NavigationPath()) == expected)
    }

    @Test func `returning to Home retains the hero destination without retaining its view`() {
        let movie = Movie(id: "movie-1", streamId: 1, name: "Film")
        let hero = HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: "")
        let router = DeepLinkRouter()
        router.homePath = DetailNavigation.appending(hero, to: router.homePath)
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
        #expect(DetailNavigation.appending(hero, to: parent) == expected)
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
            let binding = DetailNavigation.pathBinding(in: router, at: path, fallback: fallback.binding)
            binding.wrappedValue = DetailNavigation.appending(
                .movie(movie, backdropURL: nil, logoURL: nil, overview: ""), to: binding.wrappedValue
            )
            binding.wrappedValue = DetailNavigation.appending(
                .series(series, backdropURL: nil, logoURL: nil, overview: ""), to: binding.wrappedValue
            )
            let saved = binding.wrappedValue
            router.selectedTab = .search
            router.selectedTab = tab

            // Recreated view bindings still target the same persistent owner.
            let restored = DetailNavigation.pathBinding(in: router, at: path, fallback: fallback.binding)
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
        let binding = DetailNavigation.pathBinding(in: nil, at: \.homePath, fallback: fallback.binding)
        binding.wrappedValue.append("collection")
        #expect(fallback.value.count == 1)
        #expect(DetailNavigation.pathBinding(in: nil, at: \.homePath, fallback: fallback.binding).wrappedValue == fallback.value)
        binding.wrappedValue.removeLast()
        #expect(fallback.value.isEmpty)
    }

    @Test func `match centre restores in its source area without callbacks to the unmounted rail`() {
        let router = DeepLinkRouter()
        let fallback = PathBox()
        let route = SportsMatchRoute(fixture: fixture("match"), resolved: [channel()], visibilityToken: "viewer")
        let paths: [(AppTab, ReferenceWritableKeyPath<DeepLinkRouter, NavigationPath>)] = [
            (.home, \.homePath), (.sports, \.sportsPath)
        ]

        for (tab, path) in paths {
            let binding = DetailNavigation.pathBinding(in: router, at: path, fallback: fallback.binding)
            DetailNavigation.push(route, on: binding)
            var expected = NavigationPath()
            expected.append(route)
            #expect(binding.wrappedValue == expected)
            router.selectedTab = .movies
            router.selectedTab = tab
            let restored = DetailNavigation.pathBinding(in: router, at: path, fallback: fallback.binding)
            #expect(restored.wrappedValue == expected)
            restored.wrappedValue.removeLast()
            #expect(router[keyPath: path].isEmpty)
        }
        #expect(router.moviesPath.isEmpty && router.seriesPath.isEmpty && fallback.value.isEmpty)
    }

    @Test func `back from match centre preserves the followed league parent`() {
        var parent = NavigationPath()
        parent.append(SportsFollowRoute(key: "league"))
        let route = SportsMatchRoute(fixture: fixture("match"), resolved: [], visibilityToken: "viewer")
        var path = DetailNavigation.appending(route, to: parent)
        #expect(path.count == 2)
        path.removeLast()
        #expect(path == parent)
    }

    @Test func `match centre retains its prefetched channels only for their visibility scope`() {
        let answer = [channel()]
        let route = SportsMatchRoute(fixture: fixture("match"), resolved: answer, visibilityToken: "parent")
        #expect(route.channels(visibleUnder: "parent") == answer)
        #expect(route.channels(visibleUnder: "child").isEmpty)
        #expect(route.fixture.id == "match")
        #expect(SportsMatchRoute(fixture: fixture("unknown"), resolved: [], visibilityToken: "parent").channels(visibleUnder: "parent").isEmpty)
    }

    @Test func `race session Match Centre routes remain distinct`() {
        let qualifying = SportsMatchRoute(fixture: fixture("weekend#Qualifying"), resolved: [], visibilityToken: "viewer")
        let race = SportsMatchRoute(fixture: fixture("weekend#Race"), resolved: [], visibilityToken: "viewer")
        #expect(qualifying != race)
        #expect(qualifying.fixture.eventId == race.fixture.eventId)
        var path = DetailNavigation.appending(qualifying, to: NavigationPath())
        path = DetailNavigation.appending(race, to: path)
        #expect(path.count == 2)
    }

    @Test func `shared hero push unwraps artwork models into concrete destinations`() {
        let path = PathBox()
        let movie = Movie(id: "movie-1", streamId: 1, name: "Film")
        let series = Series(id: "series-1", seriesId: 1, name: "Show")
        DetailNavigation.push(HeroItem.movie(movie, backdropURL: nil, logoURL: nil, overview: ""), on: path.binding)
        DetailNavigation.push(HeroItem.series(series, backdropURL: nil, logoURL: nil, overview: ""), on: path.binding)
        var expected = NavigationPath()
        expected.append(movie)
        expected.append(series)
        #expect(path.value == expected)
    }

    @Test func `restored match reads current status without changing its route identity`() {
        let seed = fixture("match")
        let route = SportsMatchRoute(fixture: seed, resolved: [], visibilityToken: "viewer")
        let finished = fixture("match", state: .final)
        #expect(route.currentFixture(in: [finished]) == finished)
        #expect(route.fixture == seed)
        #expect(route.currentFixture(in: []).id == "match")
        #expect(route.currentFixture(in: [fixture("other")]) == seed)
    }

    @Test func `restored race session stays on qualifying while its status advances`() throws {
        let kickoff = Date(timeIntervalSince1970: 1_800_000_000)
        let weekend = SportsFixture(
            id: "weekend", leagueId: "espn:racing/f1", leagueName: "F1", leagueAbbreviation: "F1",
            startDate: kickoff, status: SportsFixtureStatus(state: .scheduled), sessions: [
                SportsSession(kind: .qualifying, date: kickoff),
                SportsSession(kind: .race, date: kickoff.addingTimeInterval(86400))
            ]
        )
        let seed = try #require(weekend.expandedBySession(now: kickoff.addingTimeInterval(-60)).first { $0.sessionKind == .qualifying })
        let route = SportsMatchRoute(fixture: seed, resolved: [], visibilityToken: "viewer")
        let live = route.currentFixture(in: [weekend], now: kickoff.addingTimeInterval(60))
        #expect(live.id == seed.id)
        #expect(live.sessionKind == .qualifying)
        #expect(live.status.state == .inProgress)
        #expect(route.currentFixture(in: [live]) == live)
    }

    private func fixture(_ id: String, state: SportsFixtureState = .scheduled) -> SportsFixture {
        SportsFixture(
            id: id, leagueId: "espn:soccer/eng.1", leagueName: "League", leagueAbbreviation: "LEA",
            startDate: Date(timeIntervalSince1970: 1_800_000_000), status: SportsFixtureStatus(state: state)
        )
    }

    private func channel() -> ResolvedChannel {
        ResolvedChannel(
            stream: ResolvedStreamSummary(id: "live-1", name: "Sports", streamIcon: nil, epgChannelId: nil),
            playlistID: UUID(), matchedTitle: "Match", matchedStart: nil, score: 1, source: .epgTitleSubtitle, isConfident: true
        )
    }
}

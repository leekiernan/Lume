import Foundation
@testable import Lume
import Testing

@MainActor
struct TVDetailMetricsTests {
    @Test func `film and series have distinct fallback title roles`() {
        #expect(TVDetailMetrics.Hero.film.titleSize == 128)
        #expect(TVDetailMetrics.Hero.series.titleSize == 104)
        #expect(TVDetailMetrics.Hero.film.titleKerning == -4)
        #expect(TVDetailMetrics.Hero.series.titleKerning == -3)
    }

    @Test func `detail actions have distinct sizes without changing generic controls`() {
        #expect(TVDetailMetrics.Action.play.height == 84)
        #expect(TVDetailMetrics.Action.secondary.height == 80)
        #expect(TVDetailMetrics.Action.play.cornerRadius == 16)
        #expect(TVDetailMetrics.Action.secondary.cornerRadius == 16)
        #expect(TVDetailMetrics.Action.standard.height == 76)
        #expect(TVDetailMetrics.Action.standard.cornerRadius == 14)
    }

    @Test func `cast slots leave room for their focused avatar`() {
        #expect(TVDetailMetrics.castAvatar == 132)
        #expect(TVDetailMetrics.castCardWidth == 150)
        #expect(TVDetailMetrics.castAvatar * 1.08 < TVDetailMetrics.castCardWidth)
    }

    @Test func `detail posters keep their own dimensions`() {
        #expect(TVDetailMetrics.posterCardWidth == 240)
        #expect(TVDetailMetrics.posterCardHeight == 360)
    }
}

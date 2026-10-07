@testable import Lume
import SwiftUI
import Testing

@MainActor
struct ContinueWatchingLayoutTests {
    @Test func `movie and episode metadata grow without widening the card`() throws {
        for label in ["42 minutes remaining", "Season 12, Episode 24 · 42 minutes remaining"] {
            let standard = try size(of: card(label: label), at: .large)
            let accessible = try size(of: card(label: label), at: .accessibility5)
            #expect(standard.height >= ContinueWatchingMetrics.cardHeight)
            #expect(accessible.height > standard.height)
            #expect(accessible.width == standard.width)
        }
    }

    @Test func `recent channel metadata grows with accessibility text`() throws {
        let card = ContinueWatchingChannelCard(name: "A long international channel name", logoURL: nil)
        let standard = try size(of: card, at: .large)
        let accessible = try size(of: card, at: .accessibility5)
        #expect(accessible.height > standard.height)
        #expect(accessible.width == standard.width)
    }

    @Test func `long localized metadata can wrap beyond two lines`() throws {
        let short = try size(of: card(label: "42 Minuten verbleibend"), at: .accessibility5)
        let long = try size(of: card(label: "Staffel 12, Folge 24 · Noch 42 Minuten bis zum Ende dieser Episode"), at: .accessibility5)
        #expect(long.height > short.height)
    }

    @Test func `the continue watching rail fits the growing cards`() throws {
        let content = card(label: "Season 12, Episode 24 · 42 minutes remaining")
        let rail = PosterRail<String, _>(title: Text("Continue Watching"), showAll: nil,
                                         rowHeight: ContinueWatchingMetrics.rowHeight) { content }
            .frame(width: 390)
        let standard = try size(of: rail, at: .large)
        let accessible = try size(of: rail, at: .accessibility5)
        let accessibleCard = try size(of: content, at: .accessibility5)
        #expect(accessible.height > standard.height)
        #expect(accessible.height >= accessibleCard.height)
    }

    @Test func `offscreen metadata sets the rail height before scrolling`() throws {
        let short = card(label: "42 minutes remaining")
        let long = card(label: "Season 12, Episode 24 · 42 minutes remaining in this episode of the series")
        let shortRail = PosterRail<String, _>(title: Text("Continue Watching"), showAll: nil, rowHeight: nil) { short }
            .frame(width: 390)
        let mixedRail = PosterRail<String, _>(title: Text("Continue Watching"), showAll: nil, rowHeight: nil) {
            short
            short
            long
        }
        .frame(width: 390)
        let shortSize = try size(of: shortRail, at: .accessibility5)
        let mixedSize = try size(of: mixedRail, at: .accessibility5)
        #expect(mixedSize.height > shortSize.height)
    }

    private func card(label: String) -> ContinueWatchingCard {
        ContinueWatchingCard(title: "The Long Journey Home", backdropURL: nil, posterURL: nil,
                             logoURL: nil, fraction: 0.4, label: label)
    }

    private func size(of view: some View, at size: DynamicTypeSize) throws -> CGSize {
        let renderer = ImageRenderer(content: view.dynamicTypeSize(size))
        let image = try #require(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }
}

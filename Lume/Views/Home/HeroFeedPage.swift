import SwiftUI

/// The common hero-and-rails rendering surface. It owns no feed, queries,
/// navigation path, warm-start validation, tasks or selection/focus state.
struct HeroFeedPage<Rows: View>: View {
    let heroItems: [HeroItem]
    let reservesHero: Bool
    let warmStartBackdropURL: URL?
    /// Resolved only for an empty, reserved standard hero, as before. tvOS
    /// renders the backdrop and never asks for the portrait warm-start poster.
    var warmStartPosterURL: () -> URL? = { nil }
    var hidesScrollIndicators = false
    let onSelectHero: (HeroItem) -> Void
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        #if os(tvOS)
            TVHomeScreen(
                heroItems: heroItems, reservesHero: reservesHero,
                warmStartBackdropURL: warmStartBackdropURL, onSelectHero: onSelectHero,
                rows: rows
            )
        #else
            HeroFeedLayout(reservesHero: reservesHero, hidesScrollIndicators: hidesScrollIndicators, hero: {
                if !heroItems.isEmpty {
                    HomeHeroCarousel(items: heroItems)
                } else if reservesHero {
                    HomeHeroWarmStart(backdropURL: warmStartBackdropURL, posterURL: warmStartPosterURL())
                }
            }, rows: rows)
        #endif
    }
}

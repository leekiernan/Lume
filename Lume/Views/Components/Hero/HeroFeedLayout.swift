import SwiftUI

/// Standard hub geometry, without owning feed, navigation or hero state.
struct HeroFeedLayout<Hero: View, Rows: View>: View {
    let reservesHero: Bool
    var hidesScrollIndicators = false
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PosterCardMetrics.sectionSpacing) {
                hero()
                rows()
            }
            .padding(.top, reservesHero ? 0 : PosterCardMetrics.sectionVerticalPadding)
            .padding(.bottom, PosterCardMetrics.sectionVerticalPadding)
        }
        .scrollIndicators(hidesScrollIndicators ? .hidden : .automatic)
        .background { LumeAmbientBackground() }
        .ignoresSafeArea(edges: reservesHero ? .top : [])
    }
}

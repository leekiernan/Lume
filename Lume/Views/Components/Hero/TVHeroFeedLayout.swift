#if os(tvOS)
    import SwiftUI

    /// Shared immersive hero/rails geometry. Content and focus targets belong
    /// to each feature; the fold never changes layout in response to focus.
    struct TVHeroFeedLayout<Backdrop: View, Showcase: View, Rows: View>: View {
        let hasHero: Bool
        var onFoldChange: (Bool) -> Void = { _ in }
        @ViewBuilder let backdrop: (Bool) -> Backdrop
        @ViewBuilder let showcase: () -> Showcase
        @ViewBuilder let rows: () -> Rows
        @State private var zone: TVHomeZone = .expanded
        @State private var containerHeight: CGFloat = 0

        private var showcaseHeight: CGFloat {
            max(containerHeight - TVHomeMetrics.rowPeek, 0)
        }

        var body: some View {
            ZStack {
                if hasHero { backdrop(zone != .expanded) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TVHomeMetrics.rowSpacing) {
                        if hasHero { showcase() }
                        rows()
                    }
                    .padding(.top, hasHero ? 0 : PosterCardMetrics.sectionVerticalPadding)
                    .padding(.bottom, PosterCardMetrics.sectionVerticalPadding)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .scrollTargetBehavior(TVHomeFoldBehavior(zone: zone, showcaseHeight: hasHero ? showcaseHeight : 0))
                .onScrollGeometryChange(for: TVHomeZone.self) { geometry in
                    TVHomeZone(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                               showcaseHeight: hasHero ? showcaseHeight : 0)
                } action: { _, newZone in
                    guard newZone != zone else { return }
                    withAnimation(.easeInOut(duration: 0.5)) { zone = newZone }
                }
            }
            .ignoresSafeArea(edges: .vertical)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { containerHeight = $0 }
            .onChange(of: zone) { _, newZone in onFoldChange(newZone != .expanded) }
        }
    }
#endif

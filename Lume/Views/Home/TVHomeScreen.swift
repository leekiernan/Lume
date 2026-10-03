//
//  TVHomeScreen.swift
//  Lume
//
//  The immersive tvOS home screen, modelled on the Apple TV app and Apple's
//  "Creating a tvOS media catalog app in SwiftUI" sample:
//
//  • The TMDB backdrop is a FIXED full-screen layer behind the scroll view
//    (crossfading between slides), so artwork always fills the screen.
//  • The scroll content opens with a "showcase" slot sized to the screen height
//    minus `TVHomeMetrics.rowPeek`, so the first row teases at the bottom edge.
//  • `TVHomeFoldBehavior` (a custom `ScrollTargetBehavior`, in
//    `TVHomeFold.swift`) snaps the fold in three stages: the first move down
//    parks the first row mid-screen with the hero's bottom strip still visible
//    (`.strip`), the next hides the hero entirely (`.rows`), and moving back
//    up restores the full hero.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    // MARK: - Screen

    /// The immersive home: full-screen backdrop behind a single native vertical
    /// ScrollView. tvOS owns focus and scrolling; `TVHomeFoldBehavior` only
    /// adjusts where each focus-driven scroll comes to rest.
    struct TVHomeScreen<Rows: View>: View {
        let heroItems: [HeroItem]
        /// True while a configured hero's feed is still resolving. Keeping the
        /// showcase in the hierarchy from frame one prevents the rows from
        /// drawing at the top and then jumping down by nearly a screen height.
        let reservesHero: Bool
        /// The last lead backdrop for this hero/playlist. Its bytes are already
        /// managed by ImagePipeline; this lets that one disk-cache decode start
        /// before the promoted section has produced its HeroItem.
        let warmStartBackdropURL: URL?
        /// Called when the hero surface is selected; the owner navigates.
        let onSelectHero: (HeroItem) -> Void
        @ViewBuilder var rows: Rows

        @State private var model = TVHeroCarouselModel<HeroItem>(prefetchURL: \.imageURL)
        @State private var zone: TVHomeZone = .expanded
        @State private var containerHeight: CGFloat = 0

        private var showcaseHeight: CGFloat {
            max(containerHeight - TVHomeMetrics.rowPeek, 0)
        }

        private var belowFold: Bool {
            zone != .expanded
        }

        init(
            heroItems: [HeroItem],
            reservesHero: Bool = false,
            warmStartBackdropURL: URL? = nil,
            onSelectHero: @escaping (HeroItem) -> Void,
            @ViewBuilder rows: () -> Rows
        ) {
            self.heroItems = heroItems
            self.reservesHero = reservesHero
            self.warmStartBackdropURL = warmStartBackdropURL
            self.onSelectHero = onSelectHero
            self.rows = rows()
        }

        private var hasHero: Bool {
            reservesHero || !heroItems.isEmpty
        }

        var body: some View {
            ZStack {
                if hasHero {
                    TVHeroBackdrop(
                        model: model,
                        belowFold: belowFold,
                        warmStartBackdropURL: warmStartBackdropURL
                    )
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TVHomeMetrics.rowSpacing) {
                        if hasHero {
                            TVHeroShowcase(model: model, onSelect: onSelectHero)
                        }
                        rows
                    }
                    // The hero fills the top inset itself when it's showing.
                    .padding(.top, hasHero ? 0 : PosterCardMetrics.sectionVerticalPadding)
                    .padding(.bottom, PosterCardMetrics.sectionVerticalPadding)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .scrollTargetBehavior(TVHomeFoldBehavior(
                    zone: zone,
                    showcaseHeight: hasHero ? showcaseHeight : 0
                ))
                .onScrollGeometryChange(for: TVHomeZone.self) { geometry in
                    TVHomeZone(
                        offset: geometry.contentOffset.y + geometry.contentInsets.top,
                        showcaseHeight: hasHero ? showcaseHeight : 0
                    )
                } action: { _, newZone in
                    guard newZone != zone else { return }
                    withAnimation(.easeInOut(duration: 0.5)) { zone = newZone }
                }
            }
            // Full-bleed vertically so the showcase spans the real screen height
            // and the first row peeks at the true bottom edge. Ignoring on the
            // CONTAINER (not the ScrollView) matters: a ScrollView keeps its
            // safe-area-reduced frame and quietly ignores this modifier. The
            // horizontal safe area stays so rows keep their overscan inset.
            .ignoresSafeArea(edges: .vertical)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                containerHeight = height
            }
            .onChange(of: zone) { _, newZone in
                model.isPaused = newZone != .expanded
            }
            .onChange(of: heroItems) { _, items in
                model.configure(items: items)
            }
            .onAppear { model.configure(items: heroItems) }
        }
    }

    // MARK: - Backdrop layer

    /// The fixed full-screen artwork behind the scroll content. Crossfades on
    /// page changes and frosts/dims once the user scrolls below the fold —
    /// Apple's material-masked-by-gradient treatment from the media catalog
    /// sample, plus a bottom scrim that keeps the hero copy legible.
    private struct TVHeroBackdrop: View {
        let model: TVHeroCarouselModel<HeroItem>
        let belowFold: Bool
        let warmStartBackdropURL: URL?
        @Environment(\.displayScale) private var displayScale

        private var backdropURL: URL? {
            model.currentHero?.imageURL ?? warmStartBackdropURL
        }

        var body: some View {
            ZStack {
                Color.black

                if let backdropURL {
                    HeroArtworkImage(url: backdropURL)
                        // Keyed by slide so a page change swaps views, and the
                        // opacity transition (driven by the model's animated index
                        // change) reads as a crossfade.
                        .id(backdropURL.absoluteString)
                        .transition(.opacity)
                }
            }
            .tvHeroBackdropTreatment(belowFold: belowFold)
            .onGeometryChange(for: CGFloat.self) { proxy in
                HeroArtworkPolicy.decodePoints(width: proxy.size.width, height: proxy.size.height) * displayScale
            } action: { pixels in
                model.setArtworkPixels(pixels)
            }
        }
    }

    // MARK: - Showcase

    /// The focusable hero surface at the top of the scroll content: title logo,
    /// overview, Details affordance and the slide dots, bottom-aligned inside a
    /// slot that fills the screen minus the first-row peek. Selecting reports
    /// the hero via `onSelect` (navigation happens in `HomeView`); left/right
    /// pages the carousel.
    private struct TVHeroShowcase: View {
        let model: TVHeroCarouselModel<HeroItem>
        let onSelect: (HeroItem) -> Void

        @Environment(\.modelContext) private var modelContext
        @FocusState private var heroFocused: Bool

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                if let hero = model.displayedHero {
                    heroContent(for: hero)
                }
            }
            // Fill the slot so the natural-height link pins to its BOTTOM —
            // the space above is what lets "up" from the focused hero reach
            // the tab bar.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            // Size the slot BEFORE `.focusSection()`: a sizing wrapper outside
            // the focus section detaches it from the focus engine and the hero
            // silently stops being focusable (focus skips from the tab bar
            // straight to the first row).
            .containerRelativeFrame(.vertical, alignment: .topLeading) { length, _ in
                max(length - TVHomeMetrics.rowPeek, 0)
            }
            .focusSection()
            .task(id: model.items.map(\.id)) {
                await model.runAutoAdvance()
            }
        }

        /// The bottom info block (natural height, pinned to the slot's bottom
        /// by the enclosing ZStack) — NOT the whole slot. Filling the slot
        /// leaves no room above the focused hero, so "up" stops reaching the
        /// tab bar and the focus engine remaps it to other keys, breaking
        /// left/right carousel paging.
        ///
        /// Only the Details pill inside is focusable (see `info(for:)`): the
        /// block itself spans the full width, and a full-width focus target
        /// projects "down" from the SCREEN CENTER — landing on the third card
        /// of the first row instead of the first. A full-width focus-section
        /// band around the pill keeps it reachable from the tab bar above.
        private func heroContent(for hero: HeroItem) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                info(for: hero)
                    .opacity(model.infoOpacity)

                TVHeroPageDots(model: model)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// CONSTANT HEIGHT across slides: the logo slot is a fixed frame and the
        /// overview always reserves its three lines. The surface is a focused
        /// element — if its frame changed per slide, the focus engine would
        /// re-scroll to track it on every manual page and the rows below would
        /// visibly jump.
        private func info(for hero: HeroItem) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                TitleLogo(
                    url: hero.logoURL,
                    title: hero.title,
                    maxWidth: 500,
                    maxHeight: 130
                ) {
                    Text(hero.title)
                        .font(.system(size: 56, weight: .bold))
                        .lineLimit(2)
                        .shadow(radius: 6)
                }
                // Fresh identity per slide: two logos have different fitted
                // sizes, and a STABLE image view interpolates between them —
                // the logo visibly "grows" into place when an animation is in
                // flight (manual paging inherits one from the focus engine).
                // The swap happens while `infoOpacity` is 0, so replacing the
                // view outright is invisible.
                .id(hero.id)
                .frame(height: 130, alignment: .bottomLeading)

                Text(hero.overview)
                    .font(.callout)
                    .lineLimit(3, reservesSpace: true)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
                    .frame(maxWidth: 640, alignment: .leading)

                // One STRUCTURALLY STABLE Button for every slide — a plain
                // content swap on a stable view, so paging never drops focus.
                // (A `NavigationLink` whose branch flips movie⇄series gets a
                // NEW identity on those pages: focus falls to the first row,
                // tvOS scrolls down to reveal it and back up on re-assert, and
                // the whole home visibly jumps.) Navigation is reported via
                // `onSelect` instead.
                //
                // The pill is the ONLY focusable element of the showcase, so
                // the focus engine projects "down" from its narrow left-edge
                // frame and lands on the FIRST card of the row below.
                //
                // The enclosing FULL-WIDTH `.focusSection()` band is what
                // keeps the narrow pill reachable from above: the tab bar's
                // buttons sit near the screen's center, and a vertical focus
                // search only considers candidates that overlap the source
                // horizontally — without the band, "down" from the tab bar
                // skips the left-edge pill and lands mid-row. (The slot-level
                // section can't catch that move: it ENCLOSES the tab bar, so
                // it is never "below" it.) The band redirects to its only
                // focusable child without affecting the pill's own outgoing
                // projection.
                HStack {
                    Button {
                        onSelect(hero)
                    } label: {
                        detailsPill
                    }
                    .buttonStyle(TVHeroSurfaceButtonStyle())
                    .focused($heroFocused)
                    .onMoveCommand { direction in
                        // Defer the page OUT of the move-command handler: tvOS
                        // delivers it inside the focus engine's animated
                        // update, and every layout change made there is
                        // implicitly animated at the UIKit layer — the info
                        // block visibly floats into place and drags the first
                        // row along. (`Transaction.disablesAnimations` can't
                        // reach that layer; it was tried and failed.) One
                        // main-actor hop later the event context is gone,
                        // making manual paging take the exact same path as
                        // auto-advance, which pages from a plain task and has
                        // only the model's own crossfades.
                        switch direction {
                        case .left: Task { model.retreat() }
                        case .right: Task { model.advance() }
                        default: break
                        }
                    }
                    // On the pill, never on the band or the slot: the menu's
                    // owner has to be focusable, and the band's sizing and
                    // section ordering are what keep the hero collapse working.
                    .heroFavoriteMenu(hero, in: modelContext)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                .padding(.top, 10)
            }
            .foregroundStyle(.white)
        }

        /// The label of the hero's Button. The focus-neutral button style adds
        /// no automatic highlight, so the pill mirrors `heroFocused` itself to
        /// flip between a glassy resting style and a solid highlighted style.
        private var detailsPill: some View {
            Label("Details", systemImage: "info.circle")
                .fontWeight(.semibold)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    heroFocused
                        ? AnyShapeStyle(.white)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
                .foregroundStyle(heroFocused ? .black : .white)
                .scaleEffect(heroFocused ? 1.04 : 1.0)
                .animation(.easeOut(duration: 0.18), value: heroFocused)
        }
    }

    /// A focus-neutral button style for the full-hero surface: it renders only
    /// the label, so tvOS adds no automatic focus highlight (which would wash
    /// the entire hero white). The `detailsPill` reflects focus instead.
    private struct TVHeroSurfaceButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }

    // MARK: - Preview

    #Preview("Immersive Home") {
        let items = [
            HeroItem.movie(
                Movie(id: "preview-hero-1", streamId: 1, name: "The Matrix"),
                backdropURL: URL(string: "https://image.tmdb.org/t/p/w1280/fNG7i7RqM1T0sP1vQmRIqRnW.jpg"),
                logoURL: nil,
                overview: "A computer hacker learns about the true nature of reality."
            ),
            HeroItem.movie(
                Movie(id: "preview-hero-2", streamId: 2, name: "Inception"),
                backdropURL: nil,
                logoURL: nil,
                overview: "A thief who steals corporate secrets through dream-sharing technology."
            )
        ]
        NavigationStack {
            TVHomeScreen(
                heroItems: items,
                onSelectHero: { _ in },
                rows: {
                    Text("Rows go here")
                        .padding(.horizontal)
                }
            )
        }
        .modelContainer(previewContainer())
    }

#endif

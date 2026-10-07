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
            TVHeroFeedLayout(hasHero: hasHero, onFoldChange: { model.isPaused = $0 }, backdrop: { belowFold in
                TVHeroBackdrop(model: model, belowFold: belowFold, warmStartBackdropURL: warmStartBackdropURL)
            }, showcase: {
                TVHeroShowcase(model: model, onSelect: onSelectHero)
            }, rows: {
                rows
            })
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
                // The board's unloaded hero: Ink with a violet glow, so a slow
                // or missing backdrop still reads as Lume rather than black.
                LumeAmbientBackground(style: .hero)

                if let backdropURL {
                    HeroArtworkImage(url: backdropURL)
                        // Keyed by slide so a page change swaps views, and the
                        // opacity transition (driven by the model's animated index
                        // change) reads as a crossfade.
                        .id(backdropURL.absoluteString)
                        .transition(.opacity)
                }

                // The board's leading scrim into Night, behind the hero copy.
                // (The Sports hub draws its own.)
                LinearGradient(
                    stops: [
                        .init(color: .lumeNight.opacity(0.95), location: 0),
                        .init(color: .lumeNight.opacity(0.5), location: 0.45),
                        .init(color: .lumeNight.opacity(0), location: 0.7)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .tvHeroBackdropTreatment(belowFold: belowFold)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                model.setArtworkGeometry(.init(width: size.width, height: size.height, displayScale: displayScale))
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
            VStack(alignment: .leading, spacing: 22) {
                TitleLogo(
                    url: hero.logoURL,
                    title: hero.title,
                    maxWidth: 640,
                    maxHeight: 150
                ) {
                    // The board's display title, as on the detail hero. One
                    // line that shrinks, so the slot's height holds.
                    Text(hero.title)
                        .font(.system(size: 112, weight: .heavy))
                        .kerning(-3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .shadow(radius: 10)
                        .frame(maxWidth: 760, alignment: .leading)
                }
                // Fresh identity per slide: two logos have different fitted
                // sizes, and a STABLE image view interpolates between them —
                // the logo visibly "grows" into place when an animation is in
                // flight (manual paging inherits one from the focus engine).
                // The swap happens while `infoOpacity` is 0, so replacing the
                // view outright is invisible.
                .id(hero.id)
                .frame(height: 150, alignment: .bottomLeading)

                // Reserves its line when a title has no facts, for the same
                // constant height.
                Text(verbatim: hero.facts ?? "")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.lumeTextSecondary)
                    .lineLimit(1, reservesSpace: true)

                Text(hero.overview)
                    .font(.system(size: 30))
                    .lineSpacing(6)
                    .lineLimit(3, reservesSpace: true)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
                    .frame(maxWidth: 760, alignment: .leading)

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
                .padding(.top, 14)
            }
            .foregroundStyle(.white)
        }

        /// The label of the hero's Button. The focus-neutral button style adds
        /// no automatic highlight, so the pill mirrors `heroFocused` itself to
        /// flip between a glassy resting style and a solid highlighted style.
        private var detailsPill: some View {
            Label("Details", systemImage: "info.circle")
                .font(.system(size: 30, weight: .semibold))
                .padding(.horizontal, 36)
                .frame(height: 76)
                .background(
                    heroFocused
                        ? AnyShapeStyle(.white)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule()
                )
                .foregroundStyle(heroFocused ? Color.lumeNight : .white)
                .shadow(color: .black.opacity(heroFocused ? 0.55 : 0), radius: 25, y: 20)
                .scaleEffect(heroFocused ? 1.06 : 1.0, anchor: .leading)
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
                    Text(verbatim: "Rows go here")
                        .padding(.horizontal)
                }
            )
        }
        .modelContainer(previewContainer())
    }

#endif

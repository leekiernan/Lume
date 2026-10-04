//
//  TVHeroCarousel.swift
//  Lume
//
//  The pieces of the immersive tvOS hero that Home and the Sports Hub share:
//  the carousel model (current slide, the info crossfade, the auto-advance
//  clock), its page dots, and the frost-and-scrim treatment over the fixed
//  full-screen backdrop. Each screen keeps its own showcase content.
//

#if os(tvOS)

    import SwiftUI

    /// Carousel state for the immersive hero: the featured items, the current and
    /// displayed slide, and the auto-advance clock. An `@Observable` class so the
    /// 20 Hz `progress` ticks only re-render the views that actually read
    /// `progress` (the page dots) — never the showcase or the scroll content.
    @MainActor @Observable
    final class TVHeroCarouselModel<Item: Identifiable> {
        private(set) var items: [Item] = []
        private(set) var currentIndex = 0

        /// Fill of the active page dot (0…1); doubles as the auto-advance clock
        /// so the loading-bar dot and the slide jump can never drift apart.
        private let clock = HeroAutoAdvanceClock()
        var progress: Double {
            clock.progress
        }

        /// Which hero the info overlay is showing. Deliberately LAGS the current
        /// slide: on a page change the copy fades out, swaps while invisible,
        /// then fades back in (see `crossfadeInfo`).
        private var displayedID: Item.ID?
        private(set) var infoOpacity: Double = 1

        /// Set while the hero is below the fold so the carousel doesn't page
        /// (and prefetch artwork) where nobody can see it.
        var isPaused = false

        /// The artwork to warm for a slide, when it is known up front.
        private let prefetchURL: ((Item) -> URL?)?
        private var artworkGeometry: ArtworkGeometry?

        struct ArtworkGeometry: Equatable {
            let width: CGFloat
            let height: CGFloat
            let displayScale: CGFloat
        }

        /// View geometry/display scale owns resolution. The carousel only uses
        /// it to warm exactly the rendition its backdrop will display — through
        /// the same `HeroArtworkPolicy.rendition` `HeroArtworkImage` draws with,
        /// so the two can't drift onto different cache keys.
        func setArtworkGeometry(_ geometry: ArtworkGeometry) {
            guard artworkGeometry != geometry else { return }
            artworkGeometry = geometry
            prefetchNeighbours()
        }

        init(prefetchURL: ((Item) -> URL?)? = nil) {
            self.prefetchURL = prefetchURL
        }

        var currentHero: Item? {
            items.indices.contains(currentIndex) ? items[currentIndex] : items.first
        }

        var displayedHero: Item? {
            items.first { $0.id == displayedID } ?? currentHero
        }

        func configure(items: [Item]) {
            // Stay on the slide being shown when the list refreshes around
            // it (a reorder, an item added ahead of it); else the first.
            let currentID = currentHero?.id
            self.items = items
            if let currentID, let index = items.firstIndex(where: { $0.id == currentID }) {
                currentIndex = index
            } else if !items.indices.contains(currentIndex) {
                currentIndex = 0
            }
            if displayedID == nil || !items.contains(where: { $0.id == displayedID }) {
                displayedID = items.first?.id
            }
            prefetchNeighbours()
        }

        /// Runs the auto-advance clock until cancelled: tie it to a `.task`
        /// keyed by the items, on the showcase.
        func runAutoAdvance() async {
            guard items.count > 1 else {
                clock.reset()
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: HeroAutoAdvanceClock.tickInterval)
                if Task.isCancelled { return }
                if tickAutoAdvance() { advance() }
            }
        }

        /// Pages by `delta` slides — the remote's left and right.
        func page(_ delta: Int) {
            page(by: delta)
        }

        func advance() {
            page(by: 1)
        }

        func retreat() {
            page(by: -1)
        }

        /// One 50ms tick of the auto-advance clock. Returns `true` when the bar
        /// has filled and the caller should page (the view pages so it can also
        /// re-assert hero focus, which the model knows nothing about).
        func tickAutoAdvance() -> Bool {
            clock.tick(isPaused: isPaused, hasMultipleItems: items.count > 1)
        }

        private func page(by delta: Int) {
            guard items.count > 1 else { return }
            clock.reset()
            // Animate the index change so the backdrop (keyed by hero id with an
            // opacity transition) crossfades rather than swapping hard.
            withAnimation(.easeInOut(duration: 0.8)) {
                currentIndex = (currentIndex + delta + items.count) % items.count
            }
            crossfadeInfo()
            prefetchNeighbours()
        }

        /// Fades the info overlay out, swaps it while invisible, then fades back
        /// in. Reading `currentHero` in the completion (not a captured value)
        /// self-heals rapid paging to whatever slide is current on reappear.
        private func crossfadeInfo() {
            guard displayedID != currentHero?.id else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                infoOpacity = 0
            } completion: {
                self.displayedID = self.currentHero?.id
                withAnimation(.easeOut(duration: 0.45)) {
                    self.infoOpacity = 1
                }
            }
        }

        /// Warms the cache for the slides on either side so crossfades land on an
        /// already-decoded image instead of a placeholder flash.
        private func prefetchNeighbours() {
            let count = items.count
            guard count > 1, let prefetchURL, let geometry = artworkGeometry else { return }
            let renditions = [(currentIndex - 1 + count) % count, (currentIndex + 1) % count]
                .compactMap { prefetchURL(items[$0]) }
                .map {
                    HeroArtworkPolicy.rendition(
                        url: $0, width: geometry.width, height: geometry.height, displayScale: geometry.displayScale
                    )
                }
            guard let pixels = renditions.first?.decodeSizeInPixels else { return }
            let urls = renditions.compactMap(\.url)
            Task { await ImagePipeline.shared.prefetch(urls, maxPixelSize: pixels) }
        }
    }

    /// Renders only the page dots, so the model's 20 Hz `progress` ticks
    /// re-render this leaf and nothing else.
    struct TVHeroPageDots<Item: Identifiable>: View {
        let model: TVHeroCarouselModel<Item>

        var body: some View {
            if model.items.count > 1 {
                HeroPageIndicator(
                    count: model.items.count,
                    activeIndex: model.currentIndex,
                    progress: model.progress
                )
            }
        }
    }

    extension View {
        /// The fixed backdrop's legibility layers: frosted glass creeping up
        /// from the bottom, a scrim under the hero copy, and a dim once the
        /// viewer is below the fold. Full-screen and inert.
        func tvHeroBackdropTreatment(belowFold: Bool) -> some View {
            overlay {
                // Frosted glass that creeps up from the bottom: a light wash
                // behind the peeking row when expanded, the whole screen once
                // the user is below the fold.
                Rectangle()
                    .fill(.regularMaterial)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.2),
                                .init(color: .black.opacity(belowFold ? 1 : 0.3), location: 0.375),
                                .init(color: .black.opacity(belowFold ? 1 : 0), location: 0.5)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    }
            }
            .overlay {
                // Bottom scrim so the title and overview stay legible over
                // bright artwork.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.3),
                        .init(color: .black.opacity(0.45), location: 0.62),
                        .init(color: .black.opacity(0.85), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay {
                // Extra dim below the fold so the rows read against a calm,
                // near-black background that still carries the artwork's tint.
                Color.black.opacity(belowFold ? 0.45 : 0)
            }
            .compositingGroup()
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

#endif

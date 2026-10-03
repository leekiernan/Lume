//
//  TVSportsHeroShowcase.swift
//  Lume
//
//  The tvOS Sports Hub's immersive top, built like Home's: a fixed
//  full-screen backdrop behind the page (`TVSportsHeroBackdrop`) and a
//  showcase slot one screen tall less the first rail's peek. The hub's header
//  sits at the slot's top; the headlined game — a carousel of today's and the
//  week's best, paged with left and right and auto-advancing like Home's — at
//  its foot. `TVHomeFoldBehavior` folds it away as the viewer moves down.
//

#if os(tvOS)

    import SwiftUI

    typealias TVSportsHeroModel = TVHeroCarouselModel<SportsHeroSelectionMachine.Candidate>

    struct TVSportsHeroShowcase<Header: View>: View {
        let model: TVSportsHeroModel
        let availability: (SportsFixture) -> SportsChannelAvailability
        let showsScore: (SportsFixture) -> Bool
        var focus: FocusState<TVSportsFocus?>.Binding
        let onWatch: (ResolvedChannel) -> Void
        /// Catch-up from kickoff for the slide on show, under Hide Scores.
        let onWatchFromStart: (() -> Void)?
        let onOpen: (SportsFixture) -> Void
        @ViewBuilder var header: Header

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 24)
                if let hero = model.displayedHero?.fixture {
                    TVSportsHubHero(
                        fixture: hero,
                        availability: availability(hero),
                        showsScore: showsScore(hero),
                        watchFocus: focus,
                        onWatch: onWatch,
                        onWatchFromStart: onWatchFromStart,
                        onOpen: { onOpen(hero) },
                        onPage: model.items.count > 1 ? { model.page($0) } : nil
                    )
                    .padding(.horizontal, TVSportsMetrics.railInset)
                    .opacity(model.infoOpacity)
                }
                TVHeroPageDots(model: model)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                    .padding(.bottom, 24)
            }
            // Sized before any focus section, as Home's showcase is: a sizing
            // wrapper outside one detaches it from the focus engine.
            .containerRelativeFrame(.vertical, alignment: .topLeading) { length, _ in
                max(length - TVHomeMetrics.rowPeek, 0)
            }
            .task(id: model.items.map(\.id)) {
                await model.runAutoAdvance()
            }
        }
    }

    /// The artwork of the slide on show, fixed behind the whole page and
    /// edge to edge, crossfading as the carousel pages; frosted and dimmed
    /// once the viewer is below the fold. A top scrim keeps the header legible.
    struct TVSportsHeroBackdrop: View {
        let fixture: SportsFixture?
        let belowFold: Bool

        var body: some View {
            ZStack {
                Color.black
                if let fixture {
                    SportsArtworkBackdrop(fixture: fixture, size: .hero)
                        .id(fixture.id)
                        .transition(.opacity)
                }
                LinearGradient(
                    stops: [.init(color: .black.opacity(0.7), location: 0), .init(color: .clear, location: 0.3)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(
                    stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.6)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .tvHeroBackdropTreatment(belowFold: belowFold)
        }
    }

#endif

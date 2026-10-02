//
//  SportsHubHeroCarousel.swift
//  Lume
//
//  A manual, full-bleed carousel for the Sports Hub's leading fixtures. The
//  selection machine supplies its stable semantic pick first; nearby fixtures
//  become pages rather than abruptly replacing a hero someone is reading.
//

import SwiftUI

struct SportsHubHeroCarousel: View {
    let candidates: [SportsHeroSelectionMachine.Candidate]
    let availability: (SportsFixture) -> SportsChannelAvailability
    let onWatch: (ResolvedChannel) -> Void
    let onOpen: (SportsFixture) -> Void

    @State private var currentID: String?
    @ScaledMetric(relativeTo: .body) private var heroHeight: CGFloat = 340

    private var activeIndex: Int {
        candidates.firstIndex { $0.id == currentID } ?? 0
    }

    private var itemKey: String {
        candidates.map(\.id).joined(separator: ",")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(candidates) { candidate in
                            SportsHubHeroCarouselPage(
                                fixture: candidate.fixture,
                                availability: availability(candidate.fixture),
                                onWatch: onWatch,
                                onOpen: { onOpen(candidate.fixture) }
                            )
                            .frame(width: proxy.size.width, height: heroHeight)
                            .id(candidate.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .scrollIndicators(.hidden)

                if candidates.count > 1 {
                    HeroPageIndicator(count: candidates.count, activeIndex: activeIndex, progress: 1)
                        .padding(.top, 14)
                        .padding(.trailing, 20)
                }

                #if os(macOS)
                    if candidates.count > 1 {
                        sliderControls
                    }
                #endif
            }
        }
        .frame(height: heroHeight)
        .onAppear(perform: normalizeCurrentID)
        .task(id: itemKey) { normalizeCurrentID() }
    }

    /// A user-selected page remains visible while candidates refresh. If it
    /// disappears, return to the machine's first (semantic) page.
    private func normalizeCurrentID() {
        guard !candidates.isEmpty else {
            currentID = nil
            return
        }
        guard let currentID, candidates.contains(where: { $0.id == currentID }) else {
            currentID = candidates.first?.id
            return
        }
    }

    #if os(macOS)
        private var sliderControls: some View {
            HStack {
                sliderButton(systemName: "chevron.left", offset: -1)
                Spacer()
                sliderButton(systemName: "chevron.right", offset: 1)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func sliderButton(systemName: String, offset: Int) -> some View {
            Button { move(by: offset) } label: {
                Image(systemName: systemName)
                    .font(.title2.weight(.semibold))
                    .frame(width: 44, height: 56)
                    .background(.black.opacity(0.3), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }

        private func move(by offset: Int) {
            guard !candidates.isEmpty else { return }
            let next = (activeIndex + offset + candidates.count) % candidates.count
            withAnimation(.easeInOut(duration: 0.3)) {
                currentID = candidates[next].id
            }
        }
    #endif
}

private struct SportsHubHeroCarouselPage: View {
    let fixture: SportsFixture
    let availability: SportsChannelAvailability
    let onWatch: (ResolvedChannel) -> Void
    let onOpen: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SportsArtworkBackdrop(fixture: fixture, size: .hero)
            // Artwork and the team-colour fallback dissolve into the page's
            // black canvas rather than ending in a visible rectangular panel.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.05), location: 0),
                    .init(color: .black.opacity(0.32), location: 0.42),
                    .init(color: .black.opacity(0.88), location: 0.82),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            SportsHubHeroCard(fixture: fixture, availability: availability, onWatch: onWatch, onOpen: onOpen)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 30)
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
    }
}

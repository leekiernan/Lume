//
//  TVSportsHubScreen+Highlights.swift
//  Lume
//
//  The tvOS hub's "Big this week": loading and ranking it, resolving channels
//  for its near-term games, and the page a profile that follows nothing yet
//  gets — the biggest event headlined, the rest below, and Manage Teams.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    extension TVSportsHubScreen {
        func loadHighlights() async {
            let request = highlightsLoad.begin()
            let followedTeams = Set(follows.follows.filter { $0.kind == .team }.map(\.key))
            let result = await SportsHighlightsPipeline.run(
                container: modelContext.container, restriction: restriction, followedTeamIds: followedTeams,
                overrides: SportsFlagshipOverrides.shared.marks
            )
            guard !Task.isCancelled else { return }
            highlightsLoad.finish(request, result: result)
        }

        func highlightAvailability(_ fixture: SportsFixture) -> SportsChannelAvailability {
            SportsChannelAvailability(
                highlightsLoad.result.resolved[fixture.id], startDate: fixture.headlineDate, preference: .current
            )
        }

        /// A profile following nothing: lead with the biggest event.
        func highlightsHub(_ first: SportsHighlight) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    TVSportsHighlightHero(
                        highlight: first,
                        availability: highlightAvailability(first.fixture),
                        onWatch: watch,
                        onOpen: { selectedFixture = first.fixture }
                    )
                    .padding(.top, 100)
                    if highlightsLoad.result.highlights.count > 1 || !highlightsLoad.result.payPerView.isEmpty {
                        TVSportsHighlightsSection(
                            highlights: Array(highlightsLoad.result.highlights.dropFirst()),
                            payPerView: highlightsLoad.result.payPerView,
                            availability: highlightAvailability,
                            onSelect: { selectedFixture = $0 },
                            onWatchEvent: watchEvent
                        )
                    }
                    Button {
                        showManageTeams = true
                    } label: {
                        Label("Follow Your Teams", systemImage: "person.2.badge.plus")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 44)
                            .padding(.vertical, 20)
                    }
                    .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
                    .padding(.horizontal, 60)
                    .padding(.bottom, 60)
                }
            }
            .scrollClipDisabled()
            .background(alignment: .top) {
                TVSportsHubHeroBackdrop(fixture: first.fixture)
            }
        }
    }

#endif

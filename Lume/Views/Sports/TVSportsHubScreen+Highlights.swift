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
            let feed = await SportsHighlightsLoader.load()
            guard !Task.isCancelled else { return }
            let followedTeams = Set(follows.follows.filter { $0.kind == .team }.map(\.key))
            let now = Date()
            // Resolve the games a guide could already cover, so channel
            // availability can count towards the ranking and show on the cards.
            let near = feed.fixtures.filter {
                $0.startDate.timeIntervalSince(now) < SportsChannelAvailability.guideHorizon && $0.expectedEnd > now
            }
            let firstPass = SportsHighlights.rank(
                feed.fixtures, standings: feed.standings, followedTeamIds: followedTeams, availableIds: [], now: now
            )
            let toResolve = firstPass.map(\.fixture).filter { fixture in near.contains { $0.id == fixture.id } }
            var resolvedNow: [String: [ResolvedChannel]] = [:]
            if !toResolve.isEmpty {
                resolvedNow = await SportsChannelResolver.resolve(
                    container: modelContext.container, fixtures: toResolve, restriction: restriction
                )
            }
            guard !Task.isCancelled else { return }
            let available = Set(resolvedNow.filter { !$0.value.isEmpty }.keys)
            highlightResolved = resolvedNow
            highlights = SportsHighlights.rank(
                feed.fixtures, standings: feed.standings, followedTeamIds: followedTeams, availableIds: available, now: now
            )
        }

        func highlightAvailability(_ fixture: SportsFixture) -> SportsChannelAvailability {
            SportsChannelAvailability(
                highlightResolved[fixture.id], startDate: fixture.headlineDate, preference: .current
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
                    if highlights.count > 1 {
                        TVSportsHighlightsSection(
                            highlights: Array(highlights.dropFirst()),
                            availability: highlightAvailability,
                            onSelect: { selectedFixture = $0 }
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

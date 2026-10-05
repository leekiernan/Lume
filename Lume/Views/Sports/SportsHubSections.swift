//
//  SportsHubSections.swift
//  Lume
//
//  The Sports Hub's sectioned body, its onboarding card and its "no games"
//  state, split out of `SportsHubView` to keep each file small. The hub does the
//  fixture assembly and hands finished `SportsFixtureGroup`s down; this file only
//  renders them — a thin rule header per group, then the `FixtureCard`s — and
//  routes the card's actions back up through closures.
//

import SwiftUI

/// One rendered row on the hub: Live now, or a follow's games.
struct SportsFixtureGroup: Identifiable {
    let id: String
    let title: String
    let logoURL: URL?
    let fixtures: [SportsFixture]
    /// True when every card in the group belongs to one competition the header
    /// already names, so the cards drop their own league crest as noise. Live
    /// now and a team's row mix competitions and keep it.
    var isSingleLeague = false
    /// The follow this row is — its header opens the follow's page, and a
    /// team's row ends with its club's season.
    var followKey: String?
}

// MARK: - Sections

struct SportsSectionsView: View {
    let groups: [SportsFixtureGroup]
    let resolved: [String: [ResolvedChannel]]
    var showsEmptyState = true
    let isFollowed: (SportsTeam) -> Bool
    var onOpenDetail: (SportsFixture) -> Void
    var onWatch: (ResolvedChannel) -> Void
    var onFollowToggle: (SportsTeam) -> Void
    var onPickChannel: (SportsFixture) -> Void
    /// A row's follow, from its header: the hub narrows to that team or league.
    var onSelectFollow: (String) -> Void

    var body: some View {
        if groups.isEmpty {
            if showsEmptyState { SportsNoGamesView() }
        } else {
            ForEach(groups) { group in
                section(for: group)
            }
        }
    }

    private func section(for group: SportsFixtureGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(for: group)
            ForEach(group.fixtures) { card(for: $0, in: group) }
        }
    }

    private func card(for fixture: SportsFixture, in group: SportsFixtureGroup) -> some View {
        FixtureCard(
            fixture: fixture,
            resolved: resolved[fixture.id] ?? [],
            isFollowed: isFollowed,
            showsLeagueMark: !group.isSingleLeague,
            onOpenDetail: { onOpenDetail(fixture) },
            onWatch: onWatch,
            onFollowToggle: onFollowToggle,
            onPickChannel: { onPickChannel(fixture) },
            availability: SportsChannelAvailability(resolved[fixture.id], startDate: fixture.headlineDate, preference: .current)
        )
    }

    @ViewBuilder
    private func header(for group: SportsFixtureGroup) -> some View {
        if let followKey = group.followKey {
            Button {
                onSelectFollow(followKey)
            } label: {
                headerLabel(for: group, chevron: true)
            }
            .buttonStyle(.plain)
        } else {
            headerLabel(for: group, chevron: false)
        }
    }

    private func headerLabel(for group: SportsFixtureGroup, chevron: Bool) -> some View {
        SportsSectionHeading(title: Text(verbatim: group.title), logoURL: group.logoURL, chevron: chevron)
    }
}

// MARK: - Onboarding

struct SportsOnboardingCard: View {
    var onManageTeams: () -> Void

    var body: some View {
        SportsUnavailableState(title: "Follow Your Teams", message: SportsPresentationCopy.followTeams) {
            Button {
                onManageTeams()
            } label: {
                Label("Manage Teams", systemImage: "person.2.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

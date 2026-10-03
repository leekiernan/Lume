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
    let isFollowed: (SportsTeam) -> Bool
    var onOpenDetail: (SportsFixture) -> Void
    var onWatch: (ResolvedChannel) -> Void
    var onFollowToggle: (SportsTeam) -> Void
    var onPickChannel: (SportsFixture) -> Void
    /// A row's follow, from its header: the hub narrows to that team or league.
    var onSelectFollow: (String) -> Void

    var body: some View {
        if groups.isEmpty {
            SportsNoGamesView()
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
        HStack(spacing: 8) {
            if let logoURL = group.logoURL {
                CachedAsyncImage(url: logoURL, maxPixelSize: 24) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            }
            Text(group.title)
                .font(.headline)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1).offset(y: 6)
        }
        .padding(.bottom, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - No games

struct SportsNoGamesView: View {
    var body: some View {
        Text("No games")
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

// MARK: - Onboarding

struct SportsOnboardingCard: View {
    var onManageTeams: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Follow Your Teams", systemImage: "sportscourt")
        } description: {
            Text("Add leagues and teams to see fixtures, live scores and standings, with one tap to the channel carrying the game.")
        } actions: {
            Button {
                onManageTeams()
            } label: {
                Label("Manage Teams", systemImage: "person.2.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

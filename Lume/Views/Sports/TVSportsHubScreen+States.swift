//
//  TVSportsHubScreen+States.swift
//  Lume
//
//  The tvOS hub's whole-screen states — onboarding, locked, no games — and
//  the navigation its follows' pages push with.
//

#if os(tvOS)

    import SwiftUI

    extension TVSportsHubScreen {
        var pathBinding: Binding<NavigationPath> {
            DetailNavigation.pathBinding(in: router, at: \.sportsPath, fallback: $localPath)
        }

        func openMatchCentre(_ fixture: SportsFixture) {
            DetailNavigation.push(
                SportsMatchRoute(fixture: fixture, resolved: resolved[fixture.id] ?? [], visibilityToken: restriction.visibilityToken),
                on: pathBinding
            )
        }

        /// Pushes a follow's own page.
        func open(follow key: String) {
            pathBinding.wrappedValue.append(SportsFollowRoute(key: key))
        }

        // MARK: - States

        var onboardingState: some View {
            SportsUnavailableState(
                title: "Follow Your Teams",
                message: SportsPresentationCopy.followTeams
            ) {
                Button {
                    showManageTeams = true
                } label: {
                    Label("Manage Teams", systemImage: "person.2.badge.plus")
                        .tvSportsStateActionLabel()
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            }
        }

        var lockedState: some View {
            SportsUnavailableState(
                title: PremiumFeature.sportsHub.title,
                message: PremiumFeature.sportsHub.subtitle
            ) {
                Button {
                    showPaywall = true
                } label: {
                    Text("Unlock Sports Hub")
                        .tvSportsStateActionLabel()
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            }
        }

        var noGamesState: some View {
            SportsNoGamesView(presentation: .screen)
        }
    }

#endif

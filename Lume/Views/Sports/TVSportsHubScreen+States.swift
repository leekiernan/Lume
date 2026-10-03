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
            if let router {
                return Binding(get: { router.sportsPath }, set: { router.sportsPath = $0 })
            }
            return $localPath
        }

        /// Pushes a follow's own page.
        func open(follow key: String) {
            pathBinding.wrappedValue.append(SportsFollowRoute(key: key))
        }

        // MARK: - States

        var onboardingState: some View {
            fullScreenState(
                title: "Follow Your Teams",
                message: "Add leagues and teams to see fixtures, live scores and standings, with one tap to the channel carrying the game."
            ) {
                Button {
                    showManageTeams = true
                } label: {
                    Label("Manage Teams", systemImage: "person.2.badge.plus")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, TVSportsMetrics.actionLabelInset)
                        .padding(.vertical, 20)
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            }
        }

        var lockedState: some View {
            fullScreenState(
                title: PremiumFeature.sportsHub.title,
                message: PremiumFeature.sportsHub.subtitle
            ) {
                Button {
                    showPaywall = true
                } label: {
                    Text("Unlock Sports Hub")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, TVSportsMetrics.actionLabelInset)
                        .padding(.vertical, 20)
                }
                .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
            }
        }

        var noGamesState: some View {
            VStack(spacing: 24) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.35))
                Text("No games")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, minHeight: 560)
        }

        func fullScreenState(
            title: LocalizedStringResource,
            message: LocalizedStringResource,
            @ViewBuilder action: () -> some View
        ) -> some View {
            VStack(spacing: 24) {
                Image(systemName: "sportscourt")
                    .font(.system(size: 80))
                    .foregroundStyle(.white.opacity(0.5))
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 820)
                action()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

#endif

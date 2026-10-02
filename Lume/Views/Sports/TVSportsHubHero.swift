//
//  TVSportsHubHero.swift
//  Lume
//
//  The game the tvOS hub headlines (`SportsHubGrouping.heroFixture`): big
//  crests and score over the two teams' colours, and Watch on the channel the
//  resolver ranks first — the one press from the hub to the game. Match Centre
//  opens the detail; the rest of the channels live there.
//

#if os(tvOS)

    import SwiftUI

    struct TVSportsHubHero: View {
        let fixture: SportsFixture
        let availability: SportsChannelAvailability
        let showsScore: Bool
        var watchFocus: FocusState<TVSportsFocus?>.Binding
        let onWatch: (ResolvedChannel) -> Void
        let onOpen: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 26) {
                statusLine
                if let home = fixture.home, let away = fixture.away {
                    matchup(home: home, away: away)
                } else {
                    Text(verbatim: fixture.sessionKind.map { "\(fixture.eventShortTitle) · \(String(localized: $0.displayName))" } ?? fixture.eventTitle)
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                actions
            }
            .padding(.horizontal, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }

        // MARK: - Status

        private var statusLine: some View {
            HStack(spacing: 16) {
                switch fixture.status.state {
                case .inProgress:
                    LiveBadge(fontSize: 22)
                    if let detail = fixture.status.liveDetail(family: fixture.periodFamily, hidingScores: !showsScore) {
                        Text(verbatim: detail)
                            .font(.system(size: 26, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                default:
                    Text(verbatim: fixture.cardWhenText)
                        .font(.system(size: 26, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Text(verbatim: fixture.tournamentLine ?? fixture.leagueName)
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }

        // MARK: - Matchup

        private func matchup(home: SportsCompetitor, away: SportsCompetitor) -> some View {
            HStack(spacing: 40) {
                side(home, crestFirst: true)
                centre
                side(away, crestFirst: false)
            }
        }

        private func side(_ competitor: SportsCompetitor, crestFirst: Bool) -> some View {
            HStack(spacing: 24) {
                if crestFirst { TeamCrest(team: competitor.team, size: 120) }
                Text(verbatim: competitor.team.shortName.isEmpty ? competitor.team.name : competitor.team.shortName)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !crestFirst { TeamCrest(team: competitor.team, size: 120) }
            }
        }

        @ViewBuilder
        private var centre: some View {
            if showsScore, fixture.status.state == .inProgress || fixture.status.state == .final {
                Text(verbatim: fixture.scoreLine)
                    .font(.system(size: fixture.hasTextScores ? 64 : 104, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text("vs")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }

        // MARK: - Actions

        private var actions: some View {
            HStack(spacing: 24) {
                if case let .available(count, best) = availability {
                    Button {
                        onWatch(best)
                    } label: {
                        Label {
                            Text("Watch on \(best.stream.name)")
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                        .font(.system(size: 28, weight: .bold))
                        .padding(.horizontal, 36)
                    }
                    .buttonStyle(TVGlassButtonStyle())
                    .frame(width: 720)
                    .focused(watchFocus, equals: .heroWatch)
                    if count > 1 {
                        Text("\(count - 1) more on your channels")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Button(action: onOpen) {
                    Text("Match Centre")
                        .font(.system(size: 28, weight: .semibold))
                        .padding(.horizontal, 32)
                }
                .buttonStyle(TVGlassButtonStyle())
                .frame(width: 320)
                .focused(watchFocus, equals: .heroDetail)
            }
        }
    }

    /// The team colours the hub's top washes in behind the hero.
    struct TVSportsHubHeroBackdrop: View {
        let fixture: SportsFixture

        var body: some View {
            ZStack {
                RadialGradient(
                    colors: [fixture.homePalette.primary.opacity(0.55), .clear],
                    center: UnitPoint(x: 0.75, y: 0.2), startRadius: 0, endRadius: 1100
                )
                RadialGradient(
                    colors: [fixture.awayPalette.primary.opacity(0.35), .clear],
                    center: UnitPoint(x: 1.0, y: 0.7), startRadius: 0, endRadius: 900
                )
                LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .leading, endPoint: .center)
            }
            .frame(height: 820)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

#endif

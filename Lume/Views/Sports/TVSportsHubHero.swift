//
//  TVSportsHubHero.swift
//  Lume
//
//  The game the tvOS hub headlines (`SportsHeroSelectionMachine`): big
//  crests and score over fan art and the two teams' colours, and Watch on the
//  channel the resolver ranks first — the one press from the hub to the game —
//  or Remind Me for a game the guide doesn't reach yet. Match Centre opens the
//  detail; the rest of the channels live there.
//

#if os(tvOS)

    import SwiftUI

    struct TVSportsHubHero: View {
        let fixture: SportsFixture
        let availability: SportsChannelAvailability
        let showsScore: Bool
        var watchFocus: FocusState<TVSportsFocus?>.Binding
        let onWatch: (ResolvedChannel) -> Void
        /// Set when Hide Scores is on and the game can be replayed from its
        /// start: that becomes the main action, and joining live the second.
        var onWatchFromStart: (() -> Void)?
        let onOpen: () -> Void
        /// Left from the leading action, right from Match Centre: the
        /// carousel pages back or on.
        var onPage: ((Int) -> Void)?

        private var isAvailable: Bool {
            if case .available = availability { return true }
            return false
        }

        private var canWatchNow: Bool {
            fixture.isInProgress && isAvailable
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 26) {
                statusLine
                // One height for every slide: the focused buttons below must
                // not move as the carousel pages, or the focus engine re-scrolls
                // to follow them.
                Group {
                    if let home = fixture.home, let away = fixture.away {
                        matchup(home: home, away: away)
                    } else {
                        Text(verbatim: fixture.sessionKind.map { "\(fixture.eventShortTitle) · \(String(localized: $0.displayName))" } ?? fixture.eventTitle)
                            .font(.system(size: 64, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(height: 150, alignment: .leading)
                actions
                // Under the buttons, not between them. The line is kept on
                // every slide, empty where there's nothing to say, so the
                // buttons never move as the carousel pages.
                Text(verbatim: moreChannelsLine ?? " ")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(moreChannelsLine == nil)
            }
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

        /// "2 more on your channels", when Watch picked one of several.
        private var moreChannelsLine: String? {
            guard fixture.isInProgress, onWatchFromStart == nil, case let .available(count, _) = availability, count > 1 else {
                return nil
            }
            return String(localized: "\(count - 1) more on your channels")
        }

        private var actions: some View {
            HStack(spacing: 24) {
                if fixture.isInProgress, case let .available(_, best) = availability {
                    if let onWatchFromStart {
                        Button(action: onWatchFromStart) {
                            Label {
                                Text("Watch from Start")
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "backward.end.fill")
                            }
                            .font(.system(size: 28, weight: .bold))
                            .padding(.horizontal, 36)
                        }
                        .buttonStyle(TVGlassButtonStyle())
                        .frame(width: 560)
                        .focused(watchFocus, equals: .heroWatch)
                        .onCarouselEdge(.left, onPage)
                        Button {
                            onWatch(best)
                        } label: {
                            Text("Watch live")
                                .font(.system(size: 28, weight: .semibold))
                                .padding(.horizontal, 32)
                        }
                        .buttonStyle(TVGlassButtonStyle())
                        .frame(width: 300)
                    } else {
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
                        .onCarouselEdge(.left, onPage)
                    }
                }
                if fixture.status.state == .scheduled {
                    // Watch is for a game that's on; before kickoff the
                    // useful action is being told when it is.
                    SportsReminderButton(fixture: fixture) { label in
                        label
                            .font(.system(size: 28, weight: .bold))
                            .padding(.horizontal, 36)
                    }
                    .buttonStyle(TVGlassButtonStyle())
                    .frame(width: 400)
                    .focused(watchFocus, equals: .heroWatch)
                    .onCarouselEdge(.left, onPage)
                }
                Button(action: onOpen) {
                    Text("Match Centre")
                        .font(.system(size: 28, weight: .semibold))
                        .padding(.horizontal, 32)
                }
                .buttonStyle(TVGlassButtonStyle())
                .frame(width: 320)
                .focused(watchFocus, equals: .heroDetail)
                .onCarouselEdge(.left, canWatchNow || fixture.status.state == .scheduled ? nil : onPage)
                .onCarouselEdge(.right, onPage)
            }
        }
    }

    private extension View {
        /// Pages the carousel when the remote moves past the hero's outermost
        /// button. Deferred out of the move-command handler, as Home's hero
        /// does: tvOS delivers it inside the focus engine's animated update.
        @ViewBuilder
        func onCarouselEdge(_ edge: MoveCommandDirection, _ onPage: ((Int) -> Void)?) -> some View {
            if let onPage {
                onMoveCommand { direction in
                    guard direction == edge else { return }
                    Task { onPage(edge == .left ? -1 : 1) }
                }
            } else {
                self
            }
        }
    }

    /// The team colours the hub's top washes in behind the hero.
    struct TVSportsHubHeroBackdrop: View {
        let fixture: SportsFixture

        var body: some View {
            ZStack {
                SportsArtworkBackdrop(fixture: fixture, size: .hero)
                LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
            }
            // The hub's rails carry on below this view. Feather the artwork
            // into their black canvas instead of leaving a visible 820pt edge
            // through whichever section happens to follow the hero.
            .frame(height: 920)
            .frame(maxWidth: .infinity)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.62),
                        .init(color: .black.opacity(0.4), location: 0.86),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

#endif

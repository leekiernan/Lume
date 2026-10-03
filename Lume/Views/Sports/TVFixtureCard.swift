//
//  TVFixtureCard.swift
//  Lume
//
//  The tvOS hub's fixture card: each side's crest, name and score on its own
//  row, the status or the day and time at the top, and whether the viewer's
//  channels carry the game at the bottom. The Home rail keeps the crest-only
//  `TVFixtureLogoCard` glance; the hub is where people choose what to watch, so
//  its card names the teams and says when and where.
//

#if os(tvOS)

    import SwiftUI

    struct TVFixtureCard: View {
        let fixture: SportsFixture
        let availability: SportsChannelAvailability
        /// Off inside a rail that is already one competition.
        var showsLeagueName = true
        /// In a grid the card fills its column; in a rail it keeps its width.
        var fillsWidth = false
        var onSelect: () -> Void
        @AppStorage(SportsSyncService.hideScoresKey) private var hidesScores = false
        @State private var reveal = SportsScoreReveal.shared

        private var showsScore: Bool {
            fixture.showsScore(hidingScores: hidesScores, reveal: reveal)
        }

        /// A finished game whose score Hide Scores is holding back.
        private var canReveal: Bool {
            !showsScore && fixture.status.state == .final && fixture.hasTeams
        }

        var body: some View {
            Button(action: onSelect) {
                TVFixtureCardContent(
                    fixture: fixture,
                    availability: availability,
                    showsLeagueName: showsLeagueName,
                    showsScore: showsScore,
                    offersReveal: canReveal,
                    fillsWidth: fillsWidth
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .contextMenu {
                if canReveal {
                    Button("Reveal score", systemImage: "eye") { reveal.reveal(fixture.id) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spokenSummary))
        }

        private var spokenSummary: String {
            var line = fixture.tvSpokenSummary(showsScore: showsScore)
            if let channels = availability.label { line += ", " + channels }
            return line
        }
    }

    private struct TVFixtureCardContent: View {
        let fixture: SportsFixture
        let availability: SportsChannelAvailability
        let showsLeagueName: Bool
        let showsScore: Bool
        let offersReveal: Bool
        let fillsWidth: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                topLine
                Spacer(minLength: 10)
                if let home = fixture.home, let away = fixture.away {
                    VStack(alignment: .leading, spacing: 10) {
                        row(home)
                        row(away)
                    }
                } else {
                    eventBlock
                }
                Spacer(minLength: 10)
                channelLine
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(
                minWidth: fillsWidth ? 0 : 404, maxWidth: fillsWidth ? .infinity : 404,
                minHeight: 236, maxHeight: 236, alignment: .topLeading
            )
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .overlay(TeamPalette.gradient(home: fixture.homePalette, away: fixture.awayPalette).opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 1 : 0.1), lineWidth: isFocused ? 4 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }

        private var topLine: some View {
            HStack(spacing: 10) {
                if showsLeagueName {
                    Text(verbatim: fixture.tournamentLine ?? fixture.leagueName)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                status
            }
            .frame(minHeight: 30)
        }

        @ViewBuilder
        private var status: some View {
            switch fixture.status.state {
            case .inProgress:
                HStack(spacing: 8) {
                    LiveBadge(fontSize: 17)
                    if let detail = fixture.status.liveDetail(family: fixture.periodFamily, hidingScores: !showsScore) {
                        Text(verbatim: detail)
                            .font(.system(size: 19, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
            case .final:
                EndedBadge(fontSize: 17)
            case .postponed:
                Text(verbatim: fixture.status.localizedStoppage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            case .scheduled:
                Text(verbatim: fixture.cardWhenText)
                    .font(.system(size: 21, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }

        private func row(_ competitor: SportsCompetitor) -> some View {
            HStack(spacing: 14) {
                TeamCrest(team: competitor.team, size: 44)
                Text(verbatim: competitor.team.shortName.isEmpty ? competitor.team.name : competitor.team.shortName)
                    .font(.system(size: 25, weight: dimmed(competitor) ? .regular : .semibold))
                    .foregroundStyle(.white.opacity(dimmed(competitor) ? 0.6 : 1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if showsScore, fixture.status.state == .inProgress || fixture.status.state == .final {
                    Text(verbatim: competitor.displayScore)
                        .font(.system(size: fixture.hasTextScores || fixture.hasSetScores ? 22 : 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(dimmed(competitor) ? 0.6 : 1))
                        .lineLimit(1)
                }
            }
        }

        /// The loser of a finished game reads quieter — only when scores show.
        private func dimmed(_ competitor: SportsCompetitor) -> Bool {
            showsScore && fixture.status.state == .final && !competitor.isWinner
                && (fixture.home?.isWinner == true || fixture.away?.isWinner == true)
        }

        private var eventBlock: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: fixture.sessionKind.map { String(localized: $0.displayName) } ?? fixture.eventShortTitle)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(verbatim: fixture.sessionKind != nil ? fixture.eventShortTitle : (fixture.eventSubtitle ?? fixture.leagueName))
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }

        @ViewBuilder
        private var channelLine: some View {
            if offersReveal {
                Label("Hold to reveal the score", systemImage: "eye.slash")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            } else if fixture.status.state != .final, let label = availability.label {
                Label {
                    Text(verbatim: label)
                } icon: {
                    Image(systemName: "tv")
                }
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(availability.isAvailable ? Color.lumeAccent : .white.opacity(0.5))
                .lineLimit(1)
            }
        }
    }

#endif

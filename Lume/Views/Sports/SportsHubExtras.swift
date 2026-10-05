//
//  SportsHubExtras.swift
//  Lume
//
//  The iPhone / iPad / Mac hub's sections beyond the day's fixtures — the same
//  two the tvOS hub carries: "Big this week" (the week's biggest events past
//  the viewer's follows, each with why) and "Your teams" (a followed football
//  team's season, one card per competition, then its leading players).
//

import SwiftUI

// MARK: - Big this week

struct SportsHighlightsRail: View {
    let highlights: [SportsHighlight]
    var payPerView: [SportsPayPerView.Event] = []
    let availability: (SportsFixture) -> SportsChannelAvailability
    let onOpen: (SportsFixture) -> Void
    var onWatchEvent: (SportsPayPerView.Event) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SportsSectionHeading(title: Text("Big This Week"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(highlights) { highlight in
                        Button {
                            onOpen(highlight.fixture)
                        } label: {
                            SportsHighlightCard(highlight: highlight, availability: availability(highlight.fixture))
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(payPerView) { event in
                        Button {
                            onWatchEvent(event)
                        } label: {
                            SportsPayPerViewCard(event: event)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

/// An event listing; its host confirms playback when the event isn't live yet.
private struct SportsPayPerViewCard: View {
    let event: SportsPayPerView.Event

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SportsHighlightChip(title: Text("Pay-per-view"))
            Spacer(minLength: 4)
            Text(verbatim: event.title)
                .font(.subheadline.weight(.bold))
                .lineLimit(3)
            Text(verbatim: event.whenText(now: Date()))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            SportsPayPerViewChannelLabel(event: event)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.lumeAccent)
        }
        .sportsHighlightCardSurface { SportsPayPerViewBackdrop() }
    }
}

private struct SportsHighlightCard: View {
    let highlight: SportsHighlight
    let availability: SportsChannelAvailability

    private var fixture: SportsFixture {
        highlight.fixture
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SportsHighlightChip(title: Text(verbatim: highlight.chip))
                Spacer(minLength: 4)
                // When, on the top line, as on tvOS.
                Text(verbatim: fixture.isInProgress ? String(localized: "Live now") : fixture.cardWhenText)
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
            if let home = fixture.home, let away = fixture.away {
                HStack(spacing: 6) {
                    TeamCrest(team: home.team, size: 30)
                    TeamCrest(team: away.team, size: 30)
                }
            }
            Text(verbatim: fixture.eventShortTitleOrMatchup)
                .font(.subheadline.weight(.bold))
                .lineLimit(2)
            Text(verbatim: fixture.leagueName)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            if let label = availability.label {
                Label(label, systemImage: "tv")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(availability.isAvailable ? Color.lumeAccent : .white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .sportsHighlightCardSurface {
            ZStack {
                SportsArtworkBackdrop(fixture: fixture, size: .card)
                LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

// MARK: - Your teams

/// A team's season on its page: a card per competition, then its leading
/// players. The page loads the season (it lists the season's games too) and
/// hands it here; this only draws it.
struct SportsTeamSeasonPanel: View {
    let team: SportsTeam
    let season: SportsTeamSeason?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TeamCrest(team: team, size: 36)
                Text("\(team.name) this season")
                    .font(.title3.weight(.bold))
            }
            if let season {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(season.competitions) { SportsSeasonCompetitionCard(competition: $0) }
                    }
                }
                .scrollClipDisabled()
                if !season.leaders.isEmpty {
                    leaders(season)
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    private func leaders(_ season: SportsTeamSeason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Players").font(.subheadline.weight(.bold))
                if let name = season.leadersCompetitionName {
                    Text(verbatim: name).font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(season.leaders) { board in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(board.kind.title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(Array(board.entries.enumerated()), id: \.offset) { _, entry in
                            HStack {
                                Text(verbatim: entry.name).font(.subheadline).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(entry.value.formatted(.number)).font(.subheadline.weight(.bold)).monospacedDigit()
                            }
                        }
                    }
                    .padding(12)
                    // Fill the grid row, so boards side by side share a height.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

private struct SportsSeasonCompetitionCard: View {
    let competition: SportsSeasonCompetition

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: competition.name)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            switch competition.format {
            case let .table(table):
                place(table.position, table.points)
                VStack(spacing: 2) {
                    ForEach(table.rows) { row in
                        HStack {
                            Text(row.rank.formatted(.number)).frame(width: 22, alignment: .leading).foregroundStyle(.secondary)
                            Text(verbatim: row.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: row.points.map(String.init) ?? "–").fontWeight(.bold)
                        }
                        .font(.caption)
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(row.id == table.teamRowId ? Color.lumeAccent.opacity(0.35) : .clear)
                        )
                    }
                }
            case let .leaguePhase(phase):
                place(phase.position, phase.points, of: phase.total)
                HStack(spacing: 1.5) {
                    ForEach(1 ... max(phase.total, 1), id: \.self) { rank in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(rank == phase.position ? Color.primary : bandColor(rank, phase))
                            .frame(height: 18)
                    }
                }
                ForEach(Array(phase.bands.enumerated()), id: \.offset) { _, band in
                    Text(verbatim: "\(band.first)–\(band.last)  \(band.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case let .knockout(steps):
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.symbol)
                            .foregroundStyle(step.state == .won ? Color.blue : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: step.round).font(.caption.weight(.bold))
                            Text(verbatim: step.detailLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 250, height: 250, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // A fixed card: a long table or cup run stops at its edge rather than
        // drawing over the row below.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func place(_ position: Int, _ points: Int?, of total: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(position.formatted(.number)).font(.largeTitle.weight(.bold))
            if let total {
                Text("of \(total)").font(.caption).foregroundStyle(.secondary)
            }
            if let points {
                Text("\(points) pts").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bandColor(_ rank: Int, _ phase: SportsLeaguePhase) -> Color {
        guard let band = phase.bands.first(where: { ($0.first ... $0.last).contains(rank) }) else { return .gray.opacity(0.2) }
        return band.colorHex.flatMap { Color(hex: $0) } ?? .gray.opacity(0.5)
    }
}

extension SportsLeaderBoard.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .goals: "Goals"
        case .assists: "Assists"
        case .appearances: "Appearances"
        case .saves: "Saves"
        }
    }
}

extension SportsKnockoutStep {
    var symbol: String {
        switch state {
        case .won: "checkmark.circle.fill"
        case .lost: "xmark.circle"
        case .drawn: "equal.circle"
        case .live: "dot.radiowaves.left.and.right"
        case .next: "circle.circle"
        case .upcoming: "circle"
        }
    }

    /// "Won 4–2 v Ipswich", or the opponent and date to come.
    var detailLine: String {
        let opponent = opponent ?? ""
        let score = score ?? ""
        switch state {
        case .won: return String(localized: "Won \(score) v \(opponent)")
        case .lost: return String(localized: "Lost \(score) v \(opponent)")
        case .drawn: return String(localized: "Drew \(score) v \(opponent)")
        case .live: return String(localized: "Live v \(opponent)")
        case .next, .upcoming:
            return "\(opponent) · \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
        }
    }
}

// MARK: - Hero

/// A Sports slide's copy in the shared `HeroCarousel`, where `HeroInfo` sits
/// for a movie: when and what, the crests and score, and Watch on the channel
/// that suits this viewer — or Remind Me for a game the guide doesn't reach yet.
struct SportsHeroInfo: View {
    let fixture: SportsFixture
    let isCompact: Bool
    let availability: SportsChannelAvailability
    let onWatch: (ResolvedChannel) -> Void
    let onOpen: () -> Void
    @AppStorage(SportsSyncService.hideScoresKey) private var hideScoresSetting = false
    @State private var reveal = SportsScoreReveal.shared

    private var showsScore: Bool {
        fixture.showsScore(hidingScores: hideScoresSetting, reveal: reveal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if fixture.isInProgress {
                    LiveBadge(fontSize: 12)
                    if let detail = fixture.status.liveDetail(family: fixture.periodFamily, hidingScores: !showsScore) {
                        Text(verbatim: detail).font(.caption.weight(.bold)).monospacedDigit()
                    }
                } else {
                    Text(verbatim: fixture.cardWhenText).font(.caption.weight(.bold))
                }
                Text(verbatim: fixture.tournamentLine ?? fixture.leagueName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            if let home = fixture.home, let away = fixture.away {
                HStack(alignment: .center) {
                    side(home)
                    Spacer(minLength: 8)
                    if showsScore, fixture.status.state != .scheduled {
                        Text(verbatim: fixture.scoreLine)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    } else {
                        Text("vs").font(.title3).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer(minLength: 8)
                    side(away)
                }
            } else {
                Text(verbatim: fixture.eventTitle).font(.title2.weight(.bold)).lineLimit(2)
            }
            HStack(spacing: 10) {
                if fixture.isInProgress, case let .available(_, best) = availability {
                    Button {
                        onWatch(best)
                    } label: {
                        Label {
                            Text("Watch on \(best.stream.name)").lineLimit(1)
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.lumeAccent)
                } else if fixture.status.state == .scheduled {
                    SportsReminderButton(fixture: fixture) { label in
                        label
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.lumeAccent)
                }
                Button("Match Centre", action: onOpen)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .font(.subheadline.weight(.semibold))
            }
            .controlSize(.large)
        }
        .foregroundStyle(.white)
        .shadow(radius: 4)
        // `HeroInfo`'s insets and column, so the copy sits where a movie's does
        // and clears the page dots.
        .padding(.top, isCompact ? 16 : 24)
        .padding(.horizontal, isCompact ? 16 : 24)
        .padding(.bottom, 56)
        .frame(maxWidth: isCompact ? .infinity : 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func side(_ competitor: SportsCompetitor) -> some View {
        VStack(spacing: 6) {
            TeamCrest(team: competitor.team, size: 52)
            Text(verbatim: competitor.team.shortName.isEmpty ? competitor.team.name : competitor.team.shortName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: 120)
    }
}

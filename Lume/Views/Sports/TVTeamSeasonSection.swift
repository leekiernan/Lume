//
//  TVTeamSeasonSection.swift
//  Lume
//
//  The tvOS hub's "Your teams" section: pick a followed football team, see its
//  season — a card per competition, drawn as that competition works (table,
//  UEFA league phase, cup path), then its leading players in the league.
//  Loaded on demand from ESPN (`SportsTeamSeasonLoader`) when it appears.
//

#if os(tvOS)

    import SwiftUI

    struct TVTeamSeasonSection: View {
        let teams: [SportsTeam]
        @State private var selectedId: String?
        @State private var season: SportsTeamSeason?
        @State private var isLoading = false

        private var selected: SportsTeam? {
            teams.first { $0.id == selectedId } ?? teams.first
        }

        var body: some View {
            if let selected {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Your Teams")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    if teams.count > 1 {
                        teamPicker
                    }
                    header(selected)
                    content
                }
                .padding(.horizontal, 60)
                .focusSection()
                .task(id: selected.id) { await load(selected) }
            }
        }

        // MARK: - Picker

        private var teamPicker: some View {
            HStack(spacing: 14) {
                ForEach(teams) { team in
                    Button {
                        selectedId = team.id
                    } label: {
                        HStack(spacing: 12) {
                            TeamCrest(team: team, size: 36)
                            Text(verbatim: team.shortName.isEmpty ? team.name : team.shortName)
                                .font(.system(size: 24, weight: .semibold))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(.white.opacity(team.id == selected?.id ? 0.2 : 0.07)))
                    }
                    .buttonStyle(TVCardButtonStyle(focusScale: 1.05))
                }
            }
        }

        private func header(_ team: SportsTeam) -> some View {
            HStack(spacing: 24) {
                TeamCrest(team: team, size: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(team.name) this season")
                        .font(.system(size: 44, weight: .bold))
                    if let season, season.team.id == team.id {
                        Text(subtitle(season))
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
        }

        private func subtitle(_ season: SportsTeamSeason) -> String {
            let count = String(localized: "In \(season.competitions.count) competitions")
            guard let next = season.competitions.compactMap(\.next).min(by: { $0.startDate < $1.startDate }) else { return count }
            return count + " · " + String(localized: "next: \(next.eventShortTitleOrMatchup), \(next.cardWhenText)")
        }

        // MARK: - Content

        @ViewBuilder
        private var content: some View {
            if let season, season.team.id == selected?.id {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 32) {
                        ForEach(season.competitions) { competition in
                            Button {} label: {
                                TVSeasonCompetitionCard(competition: competition)
                            }
                            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
                if !season.leaders.isEmpty {
                    leaders(season)
                }
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }

        private func leaders(_ season: SportsTeamSeason) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("Players")
                        .font(.system(size: 32, weight: .bold))
                    if let name = season.leadersCompetitionName {
                        Text(verbatim: name)
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                HStack(alignment: .top, spacing: 32) {
                    ForEach(season.leaders) { board in
                        Button {} label: {
                            TVLeaderBoardCard(board: board)
                        }
                        .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
                    }
                }
            }
        }

        private func load(_ team: SportsTeam) async {
            if season?.team.id != team.id { season = nil }
            isLoading = true
            let loaded = await SportsTeamSeasonLoader.load(team: team)
            guard !Task.isCancelled else { return }
            season = loaded
            isLoading = false
        }
    }

    // MARK: - Competition card

    private struct TVSeasonCompetitionCard: View {
        let competition: SportsSeasonCompetition

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: competition.name)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(1)
                switch competition.format {
                case let .table(table):
                    tableBody(table)
                case let .leaguePhase(phase):
                    phaseBody(phase)
                case let .knockout(steps):
                    knockoutBody(steps)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(width: 420, height: 440, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.white.opacity(0.07)))
        }

        private func bigPlace(_ position: Int, detail: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(position.formatted(.number))
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                Text(verbatim: detail)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }

        private func tableBody(_ table: SportsTableSnapshot) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                bigPlace(table.position, detail: pointsLine(table.points, table.played))
                VStack(spacing: 4) {
                    ForEach(table.rows) { row in
                        HStack(spacing: 10) {
                            Text(row.rank.formatted(.number))
                                .frame(width: 32, alignment: .leading)
                                .foregroundStyle(.white.opacity(0.6))
                            Text(verbatim: row.name)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(verbatim: row.points.map(String.init) ?? "–")
                                .fontWeight(.bold)
                        }
                        .font(.system(size: 21))
                        .monospacedDigit()
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(row.id == table.teamRowId ? Color.lumeAccent.opacity(0.45) : .clear)
                        )
                    }
                }
            }
        }

        private func phaseBody(_ phase: SportsLeaguePhase) -> some View {
            VStack(alignment: .leading, spacing: 18) {
                bigPlace(phase.position, detail: String(localized: "of \(phase.total) · \(pointsLine(phase.points, phase.played))"))
                HStack(spacing: 3) {
                    ForEach(1 ... max(phase.total, 1), id: \.self) { rank in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(forRank: rank, in: phase))
                            .frame(height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(.white, lineWidth: rank == phase.position ? 3 : 0)
                            )
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(phase.bands.enumerated()), id: \.offset) { _, band in
                        Text(verbatim: "\(band.first)–\(band.last)  \(band.label)")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
        }

        private func color(forRank rank: Int, in phase: SportsLeaguePhase) -> Color {
            if rank == phase.position { return .white }
            guard let band = phase.bands.first(where: { ($0.first ... $0.last).contains(rank) }) else {
                return .white.opacity(0.12)
            }
            return band.colorHex.flatMap { Color(hex: $0) }?.opacity(0.85) ?? .white.opacity(0.35)
        }

        private func knockoutBody(_ steps: [SportsKnockoutStep]) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(nodeFill(step.state))
                                .overlay(Circle().strokeBorder(.white, lineWidth: step.state == .next || step.state == .live ? 4 : 0))
                                .frame(width: 22, height: 22)
                            if index < steps.count - 1 {
                                Capsule().fill(.white.opacity(0.2)).frame(width: 3)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: step.round)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(step.state == .upcoming ? .white.opacity(0.55) : .white)
                            Text(verbatim: detail(step))
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        .padding(.bottom, 14)
                    }
                    .frame(minHeight: 64, alignment: .top)
                }
            }
        }

        private func nodeFill(_ state: SportsKnockoutStep.State) -> Color {
            switch state {
            case .won: Color(hex: "4F8DF7") ?? .blue
            case .lost: .white.opacity(0.35)
            case .drawn: .white.opacity(0.6)
            case .live: .red
            case .next: .black
            case .upcoming: .white.opacity(0.12)
            }
        }

        private func detail(_ step: SportsKnockoutStep) -> String {
            let opponent = step.opponent ?? ""
            let score = step.score ?? ""
            switch step.state {
            case .won: return String(localized: "Won \(score) v \(opponent)")
            case .lost: return String(localized: "Lost \(score) v \(opponent)")
            case .drawn: return String(localized: "Drew \(score) v \(opponent)")
            case .live: return String(localized: "Live v \(opponent)")
            case .next, .upcoming:
                return "\(opponent) · \(step.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
            }
        }

        private func pointsLine(_ points: Int?, _ played: Int?) -> String {
            switch (points, played) {
            case let (points?, played?): String(localized: "\(points) pts · \(played) played")
            case let (points?, nil): String(localized: "\(points) pts")
            default: ""
            }
        }
    }

    // MARK: - Leader board

    private struct TVLeaderBoardCard: View {
        let board: SportsLeaderBoard

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                ForEach(Array(board.entries.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(verbatim: entry.name)
                            .font(.system(size: 23, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(entry.value.formatted(.number))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(26)
            .frame(width: 380, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.07)))
        }

        private var title: LocalizedStringKey {
            switch board.kind {
            case .goals: "Goals"
            case .assists: "Assists"
            case .appearances: "Appearances"
            case .saves: "Saves"
            }
        }
    }

#endif

//
//  GameDetailExtras.swift
//  Lume
//
//  The iPhone / iPad / Mac game detail's extras, matching the tvOS match
//  centre: win probability (live for US sports, or the bookmaker's view before
//  kickoff), the match-result prices and the score by period; and for a race,
//  the season in numbers. Each part draws only when its data came back, and
//  Hide Scores removes what would give a live or finished game away.
//

import SwiftUI

struct GameDetailMarkets: View {
    let detail: SportsEventDetail?
    let fixture: SportsFixture
    let hidesScores: Bool

    var body: some View {
        let probability = reading
        let periods = periodScores
        if probability != nil || periods != nil || detail?.odds != nil {
            VStack(alignment: .leading, spacing: 14) {
                if let probability {
                    probabilityView(probability.value, title: probability.title)
                }
                if let odds = detail?.odds {
                    oddsView(odds)
                }
                if let periods {
                    periodsView(periods)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var reading: (value: SportsWinProbability, title: LocalizedStringKey)? {
        switch fixture.status.state {
        case .inProgress:
            guard !hidesScores, let live = detail?.winProbability else { return nil }
            return (live, "Win probability")
        case .scheduled:
            guard let implied = detail?.odds?.impliedProbabilities else { return nil }
            return (implied, "Bookmaker's view")
        case .final, .postponed:
            return nil
        }
    }

    private var periodScores: SportsPeriodScores? {
        guard !hidesScores, fixture.status.state != .scheduled,
              let scores = detail?.periodScores, scores.home.count >= 2
        else { return nil }
        return scores
    }

    private func probabilityView(_ value: SportsWinProbability, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.bold))
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(fixture.homePalette.primary).frame(width: max(3, proxy.size.width * value.home))
                    if value.tie > 0 {
                        Rectangle().fill(.secondary).frame(width: max(3, proxy.size.width * value.tie))
                    }
                    Rectangle().fill(fixture.awayPalette.primary).frame(width: max(3, proxy.size.width * value.away))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                share(fixture.home?.team.shortName, value.home)
                Spacer()
                if value.tie > 0 {
                    share(String(localized: "Draw"), value.tie)
                    Spacer()
                }
                share(fixture.away?.team.shortName, value.away)
            }
        }
    }

    private func share(_ name: String?, _ value: Double) -> some View {
        Text(verbatim: "\(name ?? "") \(value.formatted(.percent.precision(.fractionLength(0))))")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private func oddsView(_ odds: SportsOdds) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(fixture.status.state == .scheduled ? "Odds" : "Pre-match odds").font(.subheadline.weight(.bold))
                Spacer()
                Text(verbatim: odds.provider).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                price("1", odds.home)
                if odds.draw != nil { price("X", odds.draw) }
                price("2", odds.away)
            }
        }
    }

    private func price(_ outcome: String, _ value: Double?) -> some View {
        HStack {
            Text(verbatim: outcome).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(verbatim: value?.formattedDecimalOdds ?? "–").fontWeight(.bold)
        }
        .font(.subheadline)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func periodsView(_ scores: SportsPeriodScores) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By period").font(.subheadline.weight(.bold))
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text(verbatim: "")
                    ForEach(scores.home.indices, id: \.self) { Text(verbatim: "\($0 + 1)").foregroundStyle(.secondary) }
                }
                GridRow {
                    Text(verbatim: fixture.home?.team.abbreviation ?? "").gridColumnAlignment(.leading)
                    ForEach(scores.home.indices, id: \.self) { Text(verbatim: scores.home[$0]) }
                }
                GridRow {
                    Text(verbatim: fixture.away?.team.abbreviation ?? "")
                    ForEach(scores.away.indices, id: \.self) { Text(verbatim: scores.away[$0]) }
                }
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
        }
    }
}

struct RacingSeasonCard: View {
    let fixture: SportsFixture
    @State private var season: SportsRacingSeason?

    var body: some View {
        Group {
            if let season {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Season").font(.headline)
                    if let lead = season.leadMargin {
                        Text("\(lead.leader) leads by \(lead.margin) · \(season.racesLeft) races left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Driver").gridColumnAlignment(.leading)
                            Text("Points")
                            Text("Wins")
                            Text("Poles")
                            Text("Podiums")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        ForEach(season.drivers.prefix(10)) { driver in
                            GridRow {
                                Text(verbatim: driver.name).lineLimit(1).gridColumnAlignment(.leading)
                                Text(verbatim: driver.points.map(String.init) ?? "–").fontWeight(.bold)
                                Text(driver.wins.formatted(.number))
                                Text(driver.poles.formatted(.number))
                                Text(driver.podiums.formatted(.number))
                            }
                            .font(.caption)
                            .monospacedDigit()
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: fixture.leagueId) {
            guard let league = SportsCatalog.league(id: fixture.leagueId) else { return }
            season = await SportsRacingSeasonLoader.load(league: league)
        }
    }
}

//
//  TVGameDetailMarkets.swift
//  Lume
//
//  The tvOS game detail's read-at-a-glance strip under the header: who is
//  likely to win (the provider's live probability for US sports, else what the
//  bookmaker's prices imply before kickoff), the match-result prices as decimal
//  odds, and the score by period. Each part draws only when its data came back,
//  and Hide Scores removes whatever would give a live or finished game away.
//

#if os(tvOS)

    import SwiftUI

    struct TVGameDetailMarkets: View {
        let detail: SportsEventDetail?
        let fixture: SportsFixture
        let hidesScores: Bool

        var body: some View {
            let probability = probabilityReading
            let periods = periodScores
            let odds = detail?.odds
            if probability != nil || periods != nil || odds != nil {
                HStack(alignment: .top, spacing: 40) {
                    if let probability {
                        probabilityPanel(probability)
                    }
                    if let periods {
                        periodPanel(periods)
                    }
                    if let odds {
                        oddsPanel(odds)
                    }
                }
                // Panels in a row share the tallest one's height.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        // MARK: - Probability

        private struct Reading {
            let value: SportsWinProbability
            let title: LocalizedStringKey
        }

        private var probabilityReading: Reading? {
            switch fixture.status.state {
            case .inProgress:
                guard !hidesScores, let live = detail?.winProbability else { return nil }
                return Reading(value: live, title: "Win probability")
            case .scheduled:
                guard let implied = detail?.odds?.impliedProbabilities else { return nil }
                return Reading(value: implied, title: "Bookmaker's view")
            case .final, .postponed:
                return nil
            }
        }

        private func probabilityPanel(_ reading: Reading) -> some View {
            panel(title: reading.title) {
                VStack(alignment: .leading, spacing: 12) {
                    GeometryReader { proxy in
                        HStack(spacing: 4) {
                            bar(reading.value.home, total: proxy.size.width, color: fixture.homePalette.primary)
                            if reading.value.tie > 0 {
                                bar(reading.value.tie, total: proxy.size.width, color: .white.opacity(0.45))
                            }
                            bar(reading.value.away, total: proxy.size.width, color: fixture.awayPalette.primary)
                        }
                    }
                    .frame(height: 14)
                    .clipShape(Capsule())
                    HStack {
                        label(fixture.home?.team.shortName, reading.value.home)
                        Spacer()
                        if reading.value.tie > 0 {
                            label(String(localized: "Draw"), reading.value.tie)
                            Spacer()
                        }
                        label(fixture.away?.team.shortName, reading.value.away)
                    }
                }
                .frame(width: 520)
            }
        }

        private func bar(_ share: Double, total: CGFloat, color: Color) -> some View {
            Rectangle()
                .fill(color)
                .frame(width: max(4, total * share))
        }

        private func label(_ name: String?, _ share: Double) -> some View {
            Text(verbatim: "\(name ?? "") \(share.formatted(.percent.precision(.fractionLength(0))))")
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }

        // MARK: - Periods

        private var periodScores: SportsPeriodScores? {
            guard !hidesScores, fixture.status.state != .scheduled,
                  let scores = detail?.periodScores, scores.home.count >= 2
            else { return nil }
            return scores
        }

        private func periodPanel(_ scores: SportsPeriodScores) -> some View {
            panel(title: "By period") {
                Grid(alignment: .trailing, horizontalSpacing: 26, verticalSpacing: 10) {
                    GridRow {
                        Text(verbatim: "")
                        ForEach(scores.home.indices, id: \.self) { index in
                            Text(verbatim: "\(index + 1)")
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    periodRow(fixture.home?.team.abbreviation, scores.home)
                    periodRow(fixture.away?.team.abbreviation, scores.away)
                }
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
            }
        }

        private func periodRow(_ team: String?, _ values: [String]) -> some View {
            GridRow {
                Text(verbatim: team ?? "")
                    .foregroundStyle(.white.opacity(0.75))
                    .gridColumnAlignment(.leading)
                ForEach(values.indices, id: \.self) { index in
                    Text(verbatim: values[index])
                        .foregroundStyle(.white)
                }
            }
        }

        // MARK: - Odds

        private func oddsPanel(_ odds: SportsOdds) -> some View {
            panel(title: fixture.status.state == .scheduled ? "Odds" : "Pre-match odds") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        price("1", odds.home)
                        if odds.draw != nil { price("X", odds.draw) }
                        price("2", odds.away)
                    }
                    if !odds.provider.isEmpty {
                        Text(verbatim: odds.provider)
                            .font(.system(size: 19))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }

        private func price(_ outcome: String, _ value: Double?) -> some View {
            HStack(spacing: 12) {
                Text(verbatim: outcome)
                    .foregroundStyle(.white.opacity(0.55))
                Text(verbatim: value?.formattedDecimalOdds ?? "–")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 24, weight: .bold))
            .monospacedDigit()
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
        }

        // MARK: - Chrome

        private func panel(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                content()
            }
            .padding(26)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.06)))
        }
    }

#endif

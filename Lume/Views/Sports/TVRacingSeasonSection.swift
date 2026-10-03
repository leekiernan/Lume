//
//  TVRacingSeasonSection.swift
//  Lume
//
//  A race series' season in the tvOS match centre: who leads and by how much
//  with how many races left, then each driver's points beside their wins,
//  poles and podiums (`SportsRacingSeason`, loaded on demand).
//

#if os(tvOS)

    import SwiftUI

    struct TVRacingSeasonSection: View {
        let fixture: SportsFixture
        @State private var seasonLoad = SportsRacingSeasonLoadMachine()

        var body: some View {
            Group {
                if let season = seasonLoad.season(for: fixture.leagueId) {
                    content(season)
                }
            }
            .task(id: fixture.leagueId) {
                guard let league = SportsCatalog.league(id: fixture.leagueId) else { return }
                let request = seasonLoad.begin(leagueId: league.id)
                let loaded = await SportsRacingSeasonLoader.load(league: league)
                seasonLoad.finish(request, season: loaded)
            }
        }

        private func content(_ season: SportsRacingSeason) -> some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text("Season")
                        .font(.system(size: 34, weight: .bold))
                    if let lead = season.leadMargin {
                        Text(leadLine(lead.leader, margin: lead.margin, racesLeft: season.racesLeft))
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                VStack(spacing: 4) {
                    header
                    ForEach(season.drivers.prefix(10)) { driver in
                        row(driver)
                            .tvFocusRow()
                    }
                }
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.06)))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func leadLine(_ leader: String, margin: Int, racesLeft: Int) -> String {
            String(localized: "\(leader) leads by \(margin) · \(racesLeft) races left")
        }

        private var header: some View {
            HStack(spacing: 16) {
                Text(verbatim: "#").frame(width: 50, alignment: .leading)
                Text("Driver").frame(maxWidth: .infinity, alignment: .leading)
                Text("Points").frame(width: 120, alignment: .trailing)
                Text("Wins").frame(width: 100, alignment: .trailing)
                Text("Poles").frame(width: 100, alignment: .trailing)
                Text("Podiums").frame(width: 130, alignment: .trailing)
            }
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 24)
            .frame(height: 44)
        }

        private func row(_ driver: SportsRacingSeason.Driver) -> some View {
            HStack(spacing: 16) {
                Text(driver.rank.formatted(.number))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 50, alignment: .leading)
                Text(verbatim: driver.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: driver.points.map(String.init) ?? "–")
                    .fontWeight(.bold)
                    .frame(width: 120, alignment: .trailing)
                Text(driver.wins.formatted(.number)).frame(width: 100, alignment: .trailing)
                Text(driver.poles.formatted(.number)).frame(width: 100, alignment: .trailing)
                Text(driver.podiums.formatted(.number)).frame(width: 130, alignment: .trailing)
            }
            .font(.system(size: 24))
            .monospacedDigit()
            .padding(.horizontal, 24)
            .frame(height: 52)
        }
    }

#endif

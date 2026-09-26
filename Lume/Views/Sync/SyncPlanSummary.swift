//
//  SyncPlanSummary.swift
//  Lume
//

import SwiftUI

struct SyncPlanSummary: View {
    let plan: PlaylistSyncPlan
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 14 : 10) {
            row("Will refresh", areas: plan.syncAreas, systemImage: "arrow.triangle.2.circlepath", tint: large ? .white : .accentColor)
            row("Skipped for this profile", areas: plan.skippedForProfile, systemImage: "minus.circle", tint: .secondary)
            row("Not needed for this repair", areas: plan.deferredByRepair, systemImage: "checkmark.circle", tint: .secondary)
            row("Not provided by this source", areas: plan.unsupportedBySource, systemImage: "nosign", tint: .secondary)
        }
        .padding(.bottom, large ? 20 : 12)
    }

    @ViewBuilder
    private func row(
        _ title: LocalizedStringKey,
        areas: Set<AppArea>,
        systemImage: String,
        tint: Color
    ) -> some View {
        if !areas.isEmpty {
            HStack(alignment: .top, spacing: large ? 16 : 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: large ? 30 : 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(labelFont)
                    areaNames(areas).font(valueFont).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var labelFont: Font {
        large ? .system(size: 24, weight: .semibold) : .subheadline.weight(.semibold)
    }

    private var valueFont: Font {
        large ? .system(size: 24) : .caption
    }

    private func areaNames(_ areas: Set<AppArea>) -> Text {
        AppArea.allCases
            .filter(areas.contains)
            .map { Text($0.syncPlanTitle) }
            .reduce(Text("")) { $0 + Text(", ") + $1 }
    }
}

private extension AppArea {
    var syncPlanTitle: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .series: "Series"
        case .liveTV: "Live TV"
        }
    }
}

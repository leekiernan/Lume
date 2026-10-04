import SwiftUI

extension SyncGuideStatus {
    var detail: LocalizedStringKey {
        switch self {
        case .afterSync: "After the sync"
        case .updating: "Updating in the background — you can close this"
        case .updated: "Updated"
        case .notUpdated: "Not updated"
        }
    }

    var symbol: String? {
        switch self {
        case .afterSync: "circle"
        case .updating: nil
        case .updated: "checkmark.circle.fill"
        case .notUpdated: "minus.circle"
        }
    }
}

/// One implementation per row meaning, keeping the platform's existing layout.
struct StepRowView: View {
    let step: SyncStep
    let state: SyncStepState
    let detail: String
    let fraction: Double

    var body: some View {
        #if os(tvOS)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: SyncRowMetrics.spacing) {
                    SyncStatusIcon(status: .step(state))
                    title
                    Spacer(minLength: 16)
                    activeDetail
                }
                progress.padding(.leading, SyncRowMetrics.iconSize + SyncRowMetrics.spacing)
            }
            .padding(.vertical, 6)
        #else
            HStack(alignment: .top, spacing: SyncRowMetrics.spacing) {
                SyncStatusIcon(status: .step(state))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        title
                        Spacer()
                        activeDetail
                    }
                    progress
                }
            }
            .padding(.vertical, 6)
        #endif
    }

    private var title: some View {
        Text(step.title)
            .font(SyncRowMetrics.titleFont(active: state == .active))
            .foregroundStyle(state == .pending ? .secondary : .primary)
    }

    @ViewBuilder
    private var activeDetail: some View {
        if state == .active, !detail.isEmpty {
            Text(verbatim: detail)
                .font(SyncRowMetrics.detailFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var progress: some View {
        if state == .active, fraction > 0 {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            #if os(tvOS)
                .tint(.white)
            #else
                .tint(.lumeAccent)
            #endif
        }
    }
}

/// Guide refresh runs in the background; this reports it without blocking sync.
struct SyncGuideRow: View {
    let status: SyncGuideStatus

    var body: some View {
        HStack(spacing: SyncRowMetrics.spacing) {
            SyncStatusIcon(status: .guide(status))
            Text("TV Guide").font(SyncRowMetrics.titleFont())
            #if os(tvOS)
                Spacer(minLength: 16)
            #else
                Spacer()
            #endif
            Text(status.detail)
                .font(SyncRowMetrics.detailFont)
                .foregroundStyle(.secondary)
            #if !os(tvOS)
                .multilineTextAlignment(.trailing)
            #endif
        }
        .padding(.vertical, 6)
    }
}

#if os(tvOS)
    typealias TVStepRow = StepRowView
    typealias TVSyncGuideRow = SyncGuideRow
#endif

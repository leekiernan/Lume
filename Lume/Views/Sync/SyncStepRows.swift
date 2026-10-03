//
//  SyncStepRows.swift
//  Lume
//
//  The sync screen's rows: one per sync step, and the TV guide's line under
//  them — the refresh that follows a sync with Live TV in it, running in the
//  background, so the screen reports it and never waits for it.
//

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

#if !os(tvOS)

    // MARK: - Step Row

    struct StepRowView: View {
        let step: SyncStep
        let state: SyncStepState
        let detail: String
        let fraction: Double

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                statusIcon
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(step.title)
                            .font(.subheadline)
                            .fontWeight(state == .active ? .semibold : .regular)
                            .foregroundStyle(titleColor)

                        Spacer()

                        if state == .active, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    if state == .active, fraction > 0 {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.lumeAccent)
                    }
                }
            }
            .padding(.vertical, 6)
        }

        @ViewBuilder
        private var statusIcon: some View {
            switch state {
            case .pending:
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            case .active:
                ZStack {
                    Circle()
                        .stroke(Color.lumeAccent.opacity(0.25), lineWidth: 2)
                    ProgressView()
                        .controlSize(.small)
                }
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)
            }
        }

        private var titleColor: Color {
            switch state {
            case .pending: .secondary
            case .active: .primary
            case .completed: .primary
            }
        }
    }

    /// The TV guide's line, under the steps.
    struct SyncGuideRow: View {
        let status: SyncGuideStatus

        var body: some View {
            HStack(spacing: 14) {
                Group {
                    if let symbol = status.symbol {
                        Image(systemName: symbol)
                            .font(.title3)
                            .foregroundStyle(status == .updated ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                            .symbolRenderingMode(.hierarchical)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 28, height: 28)
                Text("TV Guide")
                    .font(.subheadline)
                Spacer()
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 6)
        }
    }

#else

    struct TVStepRow: View {
        let step: SyncStep
        let state: SyncStepState
        let detail: String
        let fraction: Double

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 22) {
                    statusIcon
                        .frame(width: 40, height: 40)

                    Text(step.title)
                        .font(.system(size: 28, weight: state == .active ? .semibold : .regular))
                        .foregroundStyle(state == .pending ? .secondary : .primary)

                    Spacer(minLength: 16)

                    if state == .active, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if state == .active, fraction > 0 {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.leading, 62)
                }
            }
            .padding(.vertical, 6)
        }

        @ViewBuilder
        private var statusIcon: some View {
            switch state {
            case .pending:
                Image(systemName: "circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
            case .active:
                ProgressView()
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

    /// The TV guide's line, under the steps.
    struct TVSyncGuideRow: View {
        let status: SyncGuideStatus

        var body: some View {
            HStack(spacing: 22) {
                Group {
                    if let symbol = status.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 30))
                            .foregroundStyle(status == .updated ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                            .symbolRenderingMode(.hierarchical)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 40, height: 40)
                Text("TV Guide")
                    .font(.system(size: 28))
                Spacer(minLength: 16)
                Text(status.detail)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

#endif

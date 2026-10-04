import SwiftUI

enum SyncRowStatus: Equatable {
    case step(SyncStepState)
    case guide(SyncGuideStatus)

    var symbol: String? {
        switch self {
        case .step(.pending): "circle"
        case .step(.active): nil
        case .step(.completed): "checkmark.circle.fill"
        case let .guide(status): status.symbol
        }
    }

    var isCompleted: Bool {
        switch self {
        case .step(.completed), .guide(.updated): true
        default: false
        }
    }
}

/// Shared reporting icon, not a focus target. Platform dimensions and the
/// standard step's ring versus the guide's plain spinner stay unchanged.
struct SyncStatusIcon: View {
    let status: SyncRowStatus

    var body: some View {
        Group {
            if let symbol = status.symbol {
                Image(systemName: symbol)
                    .font(symbolFont)
                    .foregroundStyle(status.isCompleted ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .symbolRenderingMode(.hierarchical)
            } else {
                busyIndicator
            }
        }
        .frame(width: SyncRowMetrics.iconSize, height: SyncRowMetrics.iconSize)
    }

    private var symbolFont: Font {
        #if os(tvOS)
            .system(size: status == .step(.completed) ? 34 : 30)
        #else
            .title3
        #endif
    }

    @ViewBuilder
    private var busyIndicator: some View {
        #if os(tvOS)
            ProgressView()
        #else
            if status == .step(.active) {
                ZStack {
                    Circle().stroke(Color.lumeAccent.opacity(0.25), lineWidth: 2)
                    ProgressView().controlSize(.small)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        #endif
    }
}

enum SyncRowMetrics {
    #if os(tvOS)
        static let spacing: CGFloat = 22
        static let iconSize: CGFloat = 40
        static let detailFont: Font = .system(size: 22)
    #else
        static let spacing: CGFloat = 14
        static let iconSize: CGFloat = 28
        static let detailFont: Font = .caption
    #endif

    static func titleFont(active: Bool = false) -> Font {
        #if os(tvOS)
            .system(size: 28, weight: active ? .semibold : .regular)
        #else
            .subheadline.weight(active ? .semibold : .regular)
        #endif
    }
}

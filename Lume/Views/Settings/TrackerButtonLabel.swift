import SwiftUI

/// Shared row presentation only; each tracker owns its action, busy state,
/// enablement and button style. Literal titles remain localizable at call sites.
struct TrackerButtonLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isBusy = false

    var body: some View {
        #if os(tvOS)
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                Text(title)
                Spacer(minLength: 0)
                if isBusy { ProgressView() }
            }
        #else
            HStack {
                Label(title, systemImage: systemImage)
                if isBusy {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        #endif
    }
}

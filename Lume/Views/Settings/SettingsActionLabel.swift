import SwiftUI

/// Native action label plus the platform's busy indicator. Operations, disabled
/// gates and button/focus styles remain caller-owned.
struct SettingsActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isBusy = false

    var body: some View {
        #if os(tvOS)
            HStack(spacing: 16) {
                Label(title, systemImage: systemImage)
                    .labelStyle(TVSettingsIconLabelStyle())
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

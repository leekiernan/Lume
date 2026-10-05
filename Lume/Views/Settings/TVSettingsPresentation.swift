#if os(tvOS)
    import SwiftUI

    /// The identical About/Premium summary plate; content and actions stay local.
    struct TVSettingsSummary: View {
        let systemImage: String
        let title: Text
        let detail: Text

        var body: some View {
            HStack(spacing: 18) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 60, height: 60)
                    .background(.tint.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.system(size: TVSettingsMetrics.rowFontSize, weight: .semibold))
                    detail.font(.system(size: TVSettingsMetrics.secondaryFontSize)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.vertical, 8)
        }
    }

    struct TVReorderHint: View {
        var body: some View {
            Text("Move up or down to position, then select to place. Press Menu to cancel.")
                .tvSettingsFooter()
        }
    }
#endif

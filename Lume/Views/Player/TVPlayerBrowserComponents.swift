#if os(tvOS)
    import SwiftUI

    /// Shared chrome for the in-player channel browser and Multi-View picker.
    /// Callers own their columns' identity, selection, focus bindings and data.
    struct TVPlayerBrowserColumn<Rows: View>: View {
        let title: LocalizedStringKey
        let width: CGFloat
        @ViewBuilder var rows: () -> Rows

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 36)
                    .padding(.top, 30)
                    .padding(.bottom, 14)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        rows()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 36))
            .focusSection()
        }
    }

    /// Full-width remote targets, with focus distinct from persistent selection.
    /// Disabled picker rows retain their existing subdued presentation.
    struct TVPlayerBrowserRowStyle: ButtonStyle {
        var isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isSelected: isSelected)
        }

        private struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isSelected: Bool
            @Environment(\.isFocused) private var isFocused
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                configuration.label
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .black : .white)
                    .opacity(isEnabled ? 1 : 0.45)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(fill, in: .rect(cornerRadius: 14))
                    .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.02 : 1.0))
                    .animation(.easeOut(duration: 0.16), value: isFocused)
            }

            private var fill: AnyShapeStyle {
                if isFocused { return AnyShapeStyle(.white) }
                if isSelected { return AnyShapeStyle(.white.opacity(0.16)) }
                return AnyShapeStyle(.clear)
            }
        }
    }

    /// Logo-only presentation; programme text, status badges and actions stay
    /// with each browser so the picker does not acquire guide-loading work.
    struct TVPlayerBrowserChannelLogo: View {
        let url: URL?

        var body: some View {
            CachedAsyncImage(url: url, maxPixelSize: 120) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fit).padding(6)
                default:
                    Image(systemName: "tv")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 56)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
        }
    }
#endif

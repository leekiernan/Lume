#if os(tvOS)
    import SwiftUI

    /// Native Label semantics with the existing full-width settings geometry.
    /// The button, its action, focus and enabled/busy state stay caller-owned.
    struct TVSettingsIconLabelStyle: LabelStyle {
        var showsChevron = false

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 16) {
                configuration.icon
                    .font(.system(size: 22, weight: .medium))
                configuration.title
                Spacer(minLength: 0)
                if showsChevron { Image(systemName: "chevron.right") }
            }
        }
    }
#endif

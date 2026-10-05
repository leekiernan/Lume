import SwiftUI

#if os(tvOS)
    /// Only the clear label is drawn: no focus highlight, scaling or background.
    /// Each engine still owns its catcher's geometry, enablement and focus handoff.
    struct PlayerInvisibleButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }
#endif
